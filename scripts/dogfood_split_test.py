#!/usr/bin/env python3
"""Structural and source-contract tests for the dogfood operator split."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop"
ENTRYPOINT = SKILL_ROOT / "dogfood.sh"
BOARD_MODULE = SKILL_ROOT / "dogfood_board.sh"
SYNC_MODULE = SKILL_ROOT / "dogfood_sync.sh"
RETIREMENT_HELPER = SKILL_ROOT / "retire_spent_intent_diffs.py"


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def commit(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-m", message)
    return git(repo, "rev-parse", "HEAD")


class DogfoodSplitContract(unittest.TestCase):
    def test_board_responsibility_is_extracted_and_sourced(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertTrue(BOARD_MODULE.is_file())
        self.assertIn('. "$_self_dir/dogfood_board.sh"', source)
        self.assertNotIn("board_one() {", source)
        self.assertIn("board_one() {", BOARD_MODULE.read_text(encoding="utf-8"))

    def test_sync_responsibility_is_extracted_and_sourced(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")
        sync_source = SYNC_MODULE.read_text(encoding="utf-8")

        self.assertIn('. "$_self_dir/dogfood_sync.sh"', source)
        self.assertNotIn("ensure_integration_caught_up() {", source)
        self.assertIn("ensure_integration_caught_up() {", sync_source)
        self.assertEqual(
            source.count(
                'ensure_integration_caught_up "$PKGSRC" "$GH_ORG/fkst-packages"'
            ),
            2,
        )
        self.assertEqual(
            source.count('ensure_integration_caught_up "$HOST" "$REPO"'), 2
        )

    def test_operator_shell_files_leave_capacity_below_soft_limit(self) -> None:
        shell_files = [ENTRYPOINT, *sorted(SKILL_ROOT.glob("dogfood_*.sh"))]

        for path in shell_files:
            with self.subTest(path=path.name):
                lines = len(path.read_text(encoding="utf-8").splitlines())
                self.assertLess(lines, 900, f"{path} has {lines} lines")

    def test_entrypoint_and_modules_are_valid_shell(self) -> None:
        shell_files = [ENTRYPOINT, *sorted(SKILL_ROOT.glob("dogfood_*.sh"))]
        result = subprocess.run(
            ["/bin/bash", "-n", *map(str, shell_files)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_sourcing_entrypoint_exposes_board_and_operator_commands(self) -> None:
        command = (
            f'source "{ENTRYPOINT}"\n'
            "declare -F board_one cmd_board status_one cmd_doctor bin_ensure_fresh cmd_sync\n"
        )
        result = subprocess.run(
            ["/bin/bash", "-c", command],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        for name in (
            "board_one",
            "cmd_board",
            "status_one",
            "cmd_doctor",
            "bin_ensure_fresh",
            "cmd_sync",
        ):
            self.assertIn(name, result.stdout)

    def test_forward_sync_retires_before_push(self) -> None:
        sync_source = SYNC_MODULE.read_text(encoding="utf-8")

        self.assertTrue(RETIREMENT_HELPER.is_file())
        self.assertIn("retire_spent_intent_diffs.py", sync_source)
        self.assertIn('retire_spent_intent_diffs "$wt" "$repo"', sync_source)
        self.assertIn(
            "chore(migration): retire spent intent-diff manifests", sync_source
        )
        self.assertLess(
            sync_source.index('retire_spent_intent_diffs "$wt" "$repo"'),
            sync_source.index('push origin "HEAD:$INTEGRATION_BRANCH"'),
        )


class IntentDiffRetirementContract(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "retirement-test@example.invalid")
        git(self.repo, "config", "user.name", "Intent Retirement Test")
        self.write("tracked.txt", "base\n")
        self.write("migration/intent-bounded-replay.allowlist", "# protected allowlist\n")
        self.write("migration/intent-diffs/.gitkeep", "")
        self.base = commit(self.repo, "base")
        git(self.repo, "branch", "dev")
        git(self.repo, "branch", "integration")

        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        fake_gh = self.bin_dir / "gh"
        fake_gh.write_text(
            """#!/usr/bin/env python3
import json
import os
import sys

facts = json.loads(os.environ["RETIREMENT_TEST_FACTS"])
if sys.argv[1:3] != ["pr", "view"] or len(sys.argv) < 4:
    raise SystemExit(8)
fact = facts.get(sys.argv[3])
if fact is None:
    raise SystemExit(9)
print(json.dumps(fact))
""",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)

    def write(self, relative: str, content: str) -> None:
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def add_manifest(self, pr_number: int) -> str:
        relative = f"migration/intent-diffs/{pr_number}.json"
        self.write(
            relative,
            json.dumps(
                {
                    "schema": "fkst.intent-diff.v2",
                    "pr_number": pr_number,
                },
                sort_keys=True,
            )
            + "\n",
        )
        allowlist = self.repo / "migration/intent-bounded-replay.allowlist"
        allowlist.write_text(
            allowlist.read_text(encoding="utf-8") + relative + "\n",
            encoding="utf-8",
        )
        return relative

    def run_retirement(
        self,
        facts: dict[str, object],
        *,
        protected_ref: str = "HEAD",
        promote_branch: str | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PATH"] = str(self.bin_dir) + os.pathsep + env.get("PATH", "")
        env["RETIREMENT_TEST_FACTS"] = json.dumps(facts)
        argv = [
            "python3",
            str(RETIREMENT_HELPER),
            "--repo-root",
            str(self.repo),
            "--github-repo",
            "owner/repo",
            "--protected-ref",
            protected_ref,
        ]
        if promote_branch is not None:
            argv.extend(["--promote-branch", promote_branch])
        return subprocess.run(
            argv,
            cwd=self.repo,
            env=env,
            check=check,
            capture_output=True,
            text=True,
        )

    def test_promotion_retires_before_advancing_the_integration_head(self) -> None:
        git(self.repo, "checkout", "-q", "integration")
        relative = self.add_manifest(123)
        expected_head = commit(self.repo, "add manifest to integration")
        remote = self.root / "remote.git"
        git(self.root, "init", "--bare", "-q", str(remote))
        git(self.repo, "remote", "add", "origin", str(remote))
        git(self.repo, "push", "-q", "-u", "origin", "integration")

        result = self.run_retirement(
            {
                "123": {
                    "state": "MERGED",
                    "mergeCommit": {"oid": expected_head},
                }
            },
            protected_ref=expected_head,
            promote_branch="integration",
        )

        retirement = json.loads(result.stdout)
        published_head = retirement["head"]
        self.assertEqual(retirement["retired"], 1)
        self.assertEqual(retirement["paths"], [relative])
        self.assertNotEqual(published_head, expected_head)
        self.assertEqual(git(self.repo, "rev-parse", "HEAD"), expected_head)
        self.assertEqual(git(self.repo, "branch", "--show-current"), "integration")
        self.assertTrue((self.repo / relative).is_file())
        remote_head = git(
            self.repo, "ls-remote", "--heads", "origin", "refs/heads/integration"
        ).split()[0]
        self.assertEqual(remote_head, published_head)
        self.assertEqual(
            git(
                self.repo,
                "show",
                f"{published_head}:migration/intent-bounded-replay.allowlist",
            ),
            "# protected allowlist",
        )
        manifest = subprocess.run(
            ["git", "cat-file", "-e", f"{published_head}:{relative}"],
            cwd=self.repo,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(manifest.returncode, 0)
        git(self.repo, "merge-base", "--is-ancestor", expected_head, published_head)

        second = self.run_retirement(
            {}, protected_ref=published_head, promote_branch="integration"
        )
        self.assertEqual(json.loads(second.stdout)["retired"], 0)
        self.assertEqual(
            git(
                self.repo,
                "ls-remote",
                "--heads",
                "origin",
                "refs/heads/integration",
            ).split()[0],
            published_head,
        )

    def test_spent_manifest_is_retired_after_feature_merge_and_baseline_advance(self) -> None:
        git(self.repo, "checkout", "-q", "-b", "feature", "integration")
        relative = self.add_manifest(123)
        commit(self.repo, "add one-use intent manifest")

        git(self.repo, "checkout", "-q", "integration")
        git(self.repo, "merge", "--no-ff", "-m", "merge feature", "feature")
        merge_commit = git(self.repo, "rev-parse", "HEAD")

        git(self.repo, "checkout", "-q", "dev")
        self.write("tracked.txt", "advanced baseline\n")
        commit(self.repo, "advance baseline")
        git(self.repo, "checkout", "-q", "integration")
        git(self.repo, "merge", "--no-ff", "-m", "merge baseline", "dev")

        result = self.run_retirement(
            {
                "123": {
                    "state": "MERGED",
                    "mergeCommit": {"oid": merge_commit},
                }
            }
        )

        self.assertIn("retired=1", result.stdout)
        self.assertFalse((self.repo / relative).exists())
        self.assertEqual(
            (self.repo / "migration/intent-bounded-replay.allowlist").read_text(
                encoding="utf-8"
            ),
            "# protected allowlist\n",
        )
        retirement_commit = commit(self.repo, "retire spent manifest")
        changed = git(
            self.repo,
            "diff-tree",
            "--no-commit-id",
            "--name-status",
            "-r",
            f"{retirement_commit}^",
            retirement_commit,
        )
        self.assertIn(f"D\t{relative}", changed)
        self.assertIn("M\tmigration/intent-bounded-replay.allowlist", changed)
        git(self.repo, "merge-base", "--is-ancestor", merge_commit, retirement_commit)

        second = self.run_retirement({})
        self.assertIn("retired=0", second.stdout)
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")

    def test_only_merged_ancestors_are_retired(self) -> None:
        git(self.repo, "checkout", "-q", "integration")
        merged_outside_head = self.add_manifest(123)
        closed = self.add_manifest(124)
        commit(self.repo, "add active manifests")

        git(self.repo, "checkout", "-q", "-b", "unlanded")
        self.write("tracked.txt", "unlanded merge commit\n")
        unlanded_merge = commit(self.repo, "record unlanded merge")
        git(self.repo, "checkout", "-q", "integration")

        result = self.run_retirement(
            {
                "123": {
                    "state": "MERGED",
                    "mergeCommit": {"oid": unlanded_merge},
                },
                "124": {"state": "CLOSED", "mergeCommit": None},
            }
        )

        self.assertIn("retired=0", result.stdout)
        self.assertTrue((self.repo / merged_outside_head).is_file())
        self.assertTrue((self.repo / closed).is_file())
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")

    def test_unavailable_merge_fact_leaves_the_entire_sweep_unchanged(self) -> None:
        git(self.repo, "checkout", "-q", "integration")
        first = self.add_manifest(123)
        second = self.add_manifest(124)
        landed = commit(self.repo, "add two manifests")
        before_allowlist = (
            self.repo / "migration/intent-bounded-replay.allowlist"
        ).read_text(encoding="utf-8")

        result = self.run_retirement(
            {
                "123": {
                    "state": "MERGED",
                    "mergeCommit": {"oid": landed},
                }
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.repo / first).is_file())
        self.assertTrue((self.repo / second).is_file())
        self.assertEqual(
            (self.repo / "migration/intent-bounded-replay.allowlist").read_text(
                encoding="utf-8"
            ),
            before_allowlist,
        )

    def test_repository_without_intent_diff_policy_is_not_applicable(self) -> None:
        (self.repo / "migration/intent-bounded-replay.allowlist").unlink()
        shutil.rmtree(self.repo / "migration/intent-diffs")

        result = self.run_retirement({})

        self.assertIn("retired=0", result.stdout)

    def test_preexisting_policy_edit_is_refused(self) -> None:
        git(self.repo, "checkout", "-q", "integration")
        relative = self.add_manifest(123)
        landed = commit(self.repo, "add manifest")
        allowlist = self.repo / "migration/intent-bounded-replay.allowlist"
        allowlist.write_text(
            allowlist.read_text(encoding="utf-8") + "# unrelated local edit\n",
            encoding="utf-8",
        )

        result = self.run_retirement(
            {
                "123": {
                    "state": "MERGED",
                    "mergeCommit": {"oid": landed},
                }
            },
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.repo / relative).is_file())
        self.assertIn("unrelated local edit", allowlist.read_text(encoding="utf-8"))

    def test_symlinked_manifest_directory_is_refused(self) -> None:
        external = self.root / "external-manifests"
        external.mkdir()
        shutil.rmtree(self.repo / "migration/intent-diffs")
        (self.repo / "migration/intent-diffs").symlink_to(external, target_is_directory=True)
        commit(self.repo, "track symlinked manifest directory")

        result = self.run_retirement({}, check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr.lower())

    def test_symlinked_allowlist_is_refused_without_reading_its_target(self) -> None:
        external = self.root / "external-allowlist"
        external.write_text("outside must remain unchanged\n", encoding="utf-8")
        allowlist = self.repo / "migration/intent-bounded-replay.allowlist"
        allowlist.unlink()
        allowlist.symlink_to(external)
        commit(self.repo, "track symlinked allowlist")

        result = self.run_retirement({}, check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr.lower())
        self.assertEqual(
            external.read_text(encoding="utf-8"), "outside must remain unchanged\n"
        )

    def test_symlinked_numbered_manifest_is_refused_without_reading_its_target(self) -> None:
        git(self.repo, "checkout", "-q", "integration")
        relative = self.add_manifest(123)
        external = self.root / "external-manifest.json"
        external.write_text(
            json.dumps({"schema": "fkst.intent-diff.v2", "pr_number": 123}) + "\n",
            encoding="utf-8",
        )
        manifest = self.repo / relative
        manifest.unlink()
        manifest.symlink_to(external)
        landed = commit(self.repo, "track symlinked numbered manifest")

        result = self.run_retirement(
            {"123": {"state": "MERGED", "mergeCommit": {"oid": landed}}},
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr.lower())
        self.assertTrue(manifest.is_symlink())

    def test_preexisting_retirement_temp_symlink_is_refused_without_writing_target(self) -> None:
        git(self.repo, "checkout", "-q", "integration")
        relative = self.add_manifest(123)
        landed = commit(self.repo, "add manifest for retirement")
        external = self.root / "external-temp-target"
        external.write_text("outside must remain unchanged\n", encoding="utf-8")
        temporary = self.repo / "migration/.intent-bounded-replay.allowlist.retirement.tmp"
        temporary.symlink_to(external)

        result = self.run_retirement(
            {"123": {"state": "MERGED", "mergeCommit": {"oid": landed}}},
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("retirement", result.stderr.lower())
        self.assertEqual(
            external.read_text(encoding="utf-8"), "outside must remain unchanged\n"
        )
        self.assertTrue((self.repo / relative).is_file())


if __name__ == "__main__":
    unittest.main()
