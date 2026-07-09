#!/usr/bin/env python3
"""Golden-master test for dogfood launch delegation."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


from dogfood_test_helpers import (
    PLATFORM_PACKAGES,
    REPO_ROOT,
    STALE_WEBSITE_PACKAGES,
    TARGETS,
    WEBSITE_PLATFORM_PACKAGES,
    DogfoodLayout,
    git_stdout,
    run_git,
    write_executable,
)


GOLDEN_PATH = REPO_ROOT / "scripts" / "host_run_equivalence_golden.json"

def load_golden_launches() -> dict[str, object]:
    return json.loads(GOLDEN_PATH.read_text(encoding="utf-8"))


def normalize(record: dict[str, object], root: Path) -> dict[str, object]:
    root_markers = sorted({str(root), str(root.resolve())}, key=len, reverse=True)

    def norm(value: object) -> object:
        if isinstance(value, str):
            if value.startswith("/tmp/fkst-host-run-rt.") or "/fkst-host-run-rt." in value:
                return "$HOST_RUN_RUNTIME_ROOT"
            for marker in root_markers:
                value = value.replace(marker, "$ROOT")
            return value
        if isinstance(value, list):
            return [norm(item) for item in value]
        if isinstance(value, dict):
            return {key: norm(item) for key, item in value.items()}
        return value

    return norm(record)  # type: ignore[return-value]


class HostRunEquivalenceTest(unittest.TestCase):
    maxDiff = None

    def test_launchd_supervise_invocation_matches_committed_golden_for_all_targets(self) -> None:
        golden = load_golden_launches()
        self.assertEqual(set(golden), set(TARGETS))
        new_script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_root = Path(tmp)
            new_layout = DogfoodLayout(
                tmp_root / "new",
                new_script,
            )

            for target in TARGETS:
                with self.subTest(target=target):
                    new_record = normalize(new_layout.launch(target), new_layout.root)
                    if isinstance(new_record.get("env"), dict):
                        new_record["env"].pop("FKST_RUNTIME_ROOT", None)  # type: ignore[index]
                    golden_target = json.loads(json.dumps(golden[target]))
                    golden_target.get("env", {}).pop("FKST_RUNTIME_ROOT", None)
                    self.assertEqual(new_record, golden_target)
                    env = new_record["env"]  # type: ignore[index]
                    self.assertEqual(env["FKST_GITHUB_WRITE"], "1")  # type: ignore[index]
                    hydrated_roots = {
                        "substrate": new_layout.dogfood_root
                        / "substrate-dogfood"
                        / "sub"
                        / ".fkst"
                        / "run"
                        / "fkst-packages-platform",
                        "website": new_layout.dogfood_root
                        / "website-dogfood"
                        / "site"
                        / ".fkst"
                        / "run"
                        / "fkst-packages-platform",
                    }
                    if target in hydrated_roots:
                        self.assertFalse(hydrated_roots[target].exists())

    def test_website_start_uses_manifest_without_rewriting_it(self) -> None:
        new_script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(
                Path(tmp) / "stale-website",
                new_script,
                stale_website_manifest=True,
            )

            result = layout.run_start("website")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertFalse(layout.capture.exists())
            workspace = layout.dogfood_root / "website-dogfood" / "site" / "fkst.workspace.toml"
            self.assertIn(
                f"packages = {json.dumps(STALE_WEBSITE_PACKAGES.split())}",
                workspace.read_text(encoding="utf-8"),
            )
            self.assertNotIn("fkst-substrate-ref-maintainer", workspace.read_text(encoding="utf-8"))
            self.assertNotIn("integration-coverage-producer", workspace.read_text(encoding="utf-8"))
            state = json.loads(layout.launchctl_state.read_text(encoding="utf-8"))
            argv = " ".join(state["com.fkst.dogfood.ExampleOrg.website"]["argv"])
            self.assertNotIn("github-devloop-intake", argv)
            self.assertNotIn("github-ratchet-migration-slicer", argv)

    def test_non_self_host_without_platform_source_fails_before_launch(self) -> None:
        new_script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(
                Path(tmp) / "missing-platform",
                new_script,
            )
            workspace = layout.dogfood_root / "website-dogfood" / "site" / "fkst.workspace.toml"
            workspace.write_text('[workspace]\nunits = [".fkst/local-packages/*"]\n', encoding="utf-8")

            result = layout.run_start("website")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "target fkst.workspace.toml must declare external_sources(id=fkst-packages-platform)",
                result.stderr + result.stdout,
            )
            self.assertFalse(layout.capture.exists())

    def test_dogfood_sync_delegates_selective_auto_restart_to_launchd(self) -> None:
        new_script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(
                Path(tmp) / "sync-failed",
                new_script,
            )
            (layout.dogfood_root / "stable-durable-packages").mkdir(parents=True, exist_ok=True)
            (layout.dogfood_root / "stable-durable-packages" / ".fkst-supervise.pid").write_text(
                "999999\n",
                encoding="utf-8",
            )
            (layout.dogfood_root / "packages-sv-100.log").write_text(
                "TIMESTAMP=2026-01-01T00:00:00Z LEVEL=info EVENT=code_provenance "
                "ENGINE_VER=aaaaaaaa PKG_VERS=github-devloop@bbbbbbbb\n",
                encoding="utf-8",
            )
            write_executable(layout.bin_dir / "pgrep", "#!/usr/bin/env bash\nprintf '999999\\n'\n")
            write_executable(
                layout.bin_dir / "git",
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    cdir=""
                    if [ "${1:-}" = "-C" ]; then
                      cdir="$2"
                      shift 2
                    fi
                    cmd="${1:-}"
                    case "$cmd" in
                      rev-parse)
                        case "${2:-}" in
                          --git-dir) printf '.git\\n' ;;
                          --show-toplevel) printf '%s\\n' "${cdir:-$PWD}" ;;
                          --verify) exit 0 ;;
                          --short) printf 'aaaaaaaa\\n' ;;
                          origin/*|HEAD) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' ;;
                          *) printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' ;;
                        esac
                        ;;
                      fetch|status|merge-base|checkout|merge|push|reset) exit 0 ;;
                      rev-list) printf '0\\n' ;;
                      diff) printf 'changed package\\n' ;;
                      worktree) exit 0 ;;
                      *) exit 0 ;;
                    esac
                    """
                ),
            )

            result = layout.run_sync("packages")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("packages: pkg-stale -> auto-restart", result.stdout)
            self.assertFalse(layout.capture.exists())
            log = layout.launchctl_log.read_text(encoding="utf-8")
            self.assertIn("bootstrap gui/501", log)
            self.assertIn("kickstart -k gui/501/com.fkst.dogfood.ExampleOrg.packages", log)

    def test_manifest_based_launch_keeps_workspace_byte_stable(self) -> None:
        new_script = (REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh").read_text(
            encoding="utf-8"
        )
        with tempfile.TemporaryDirectory() as tmp:
            layout = DogfoodLayout(
                Path(tmp) / "byte-stable",
                new_script,
            )
            workspace = layout.dogfood_root / "website-dogfood" / "site" / "fkst.workspace.toml"
            packages = WEBSITE_PLATFORM_PACKAGES.split()
            committed_style = textwrap.dedent(
                f"""\
                [workspace]
                units = [".fkst/local-packages/*"]

                [[external_sources]]
                id = "fkst-packages-platform"
                git = {json.dumps(str(layout.dogfood_root / "website-dogfood" / "pkgs"))}
                packages = [
                {''.join(f'  {json.dumps(package)},\n' for package in packages)}]
                """
            )
            workspace.write_text(committed_style, encoding="utf-8")

            result = layout.run_start("website")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(workspace.read_text(encoding="utf-8"), committed_style)

    def test_sync_restores_generated_workspace_scratch_before_forward_merge(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = self._git_env()
            script = self._copy_dogfood_skill(root)
            dogfood_root = root / "dogfood"
            pkgs = dogfood_root / "substrate-dogfood" / "pkgs"
            host = dogfood_root / "substrate-dogfood" / "sub"
            packages_remote = self._create_branch_remote(root, "packages-remote", {"README.md": "packages\n"})
            host_remote = self._create_host_remote(root, "host-remote")
            self._clone_branch(packages_remote, pkgs, env)
            self._clone_branch(host_remote, host, env)
            base_text = self._base_workspace_text(root / "platform")
            (host / "fkst.workspace.toml").write_text(
                self._generated_workspace_text(root / "platform", PLATFORM_PACKAGES.split()),
                encoding="utf-8",
            )
            self.assertNotEqual((host / "fkst.workspace.toml").read_text(encoding="utf-8"), base_text)

            result = self._run_dogfood_sync(script, root, "substrate")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("merged + pushed", result.stdout)
            self.assertNotIn("does not merge cleanly", result.stdout)
            dev_head = git_stdout(["rev-parse", "origin/dev"], cwd=host, env=env)
            integration_head = git_stdout(["rev-parse", "origin/integration-test"], cwd=host, env=env)
            self.assertEqual(integration_head, dev_head)
            self.assertEqual(git_stdout(["status", "--porcelain"], cwd=host, env=env), "")

    def test_sync_conflict_remains_for_real_workspace_edit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = self._git_env()
            script = self._copy_dogfood_skill(root)
            dogfood_root = root / "dogfood"
            pkgs = dogfood_root / "substrate-dogfood" / "pkgs"
            host = dogfood_root / "substrate-dogfood" / "sub"
            packages_remote = self._create_branch_remote(root, "packages-remote", {"README.md": "packages\n"})
            host_remote = self._create_host_remote(root, "host-remote")
            self._clone_branch(packages_remote, pkgs, env)
            self._clone_branch(host_remote, host, env)
            real_edit = self._base_workspace_text(root / "platform").replace(
                'id = "fkst-packages-platform"\n',
                'id = "fkst-packages-platform"\nrev = "human-edit"\n',
            )
            (host / "fkst.workspace.toml").write_text(real_edit, encoding="utf-8")

            result = self._run_dogfood_sync(script, root, "substrate")

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("does not merge cleanly", result.stdout)
            dev_head = git_stdout(["rev-parse", "origin/dev"], cwd=host, env=env)
            integration_head = git_stdout(["rev-parse", "origin/integration-test"], cwd=host, env=env)
            self.assertNotEqual(integration_head, dev_head)

    def _git_env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "GIT_AUTHOR_NAME": "Dogfood Sync Test",
                "GIT_AUTHOR_EMAIL": "dogfood-sync-test@example.invalid",
                "GIT_COMMITTER_NAME": "Dogfood Sync Test",
                "GIT_COMMITTER_EMAIL": "dogfood-sync-test@example.invalid",
                "GIT_AUTHOR_DATE": "2001-09-09T01:46:40Z",
                "GIT_COMMITTER_DATE": "2001-09-09T01:46:40Z",
            }
        )
        return env

    def _copy_dogfood_skill(self, root: Path) -> Path:
        skill_dir = root / "skill"
        skill_dir.mkdir()
        script = skill_dir / "dogfood.sh"
        shutil.copy2(REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh", script)
        script.chmod(0o755)
        shutil.copy2(
            REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "workspace_manifest.py",
            skill_dir / "workspace_manifest.py",
        )
        shutil.copy2(
            REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood_launchd.sh",
            skill_dir / "dogfood_launchd.sh",
        )
        return script

    def _run_dogfood_sync(self, script: Path, root: Path, target: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "DOGFOOD_ROOT": str(root / "dogfood"),
                "DOGFOOD_REPOS": target,
                "DOGFOOD_CONFIG": str(root / "missing-config.sh"),
                "SUBSTRATE_SRC": str(root / "not-a-substrate-checkout"),
                "BIN": str(root / "missing-framework"),
                "BOT": "test-bot",
                "GH_ORG": "ExampleOrg",
                "UPSTREAM_BRANCH": "dev",
                "INTEGRATION_BRANCH": "integration-test",
                "FKST_DEVLOOP_UPSTREAM_BRANCH": "dev",
                "FKST_DEVLOOP_INTEGRATION_BRANCH": "integration-test",
                "ROLLUP_MERGE": "auto",
                "RATE_POOL": str(root / "rate-pools"),
                "LOGDIR": str(root / "dogfood"),
            }
        )
        return subprocess.run(
            [str(script), "sync", target],
            cwd=root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def _create_branch_remote(self, root: Path, name: str, files: dict[str, str]) -> Path:
        env = self._git_env()
        source = root / f"{name}-source"
        source.mkdir()
        run_git(["init", "-q"], cwd=source, env=env)
        for rel, content in files.items():
            path = source / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        run_git(["add", "."], cwd=source, env=env)
        run_git(["commit", "-q", "-m", "seed"], cwd=source, env=env)
        run_git(["branch", "dev"], cwd=source, env=env)
        run_git(["branch", "integration-test"], cwd=source, env=env)
        remote = root / name
        run_git(["init", "--bare", "-q", str(remote)], cwd=root, env=env)
        run_git(["remote", "add", "origin", str(remote)], cwd=source, env=env)
        run_git(["push", "-q", "origin", "dev", "integration-test"], cwd=source, env=env)
        return remote

    def _create_host_remote(self, root: Path, name: str) -> Path:
        env = self._git_env()
        source = root / f"{name}-source"
        source.mkdir()
        run_git(["init", "-q"], cwd=source, env=env)
        (root / "platform").mkdir()
        (source / "fkst.workspace.toml").write_text(self._base_workspace_text(root / "platform"), encoding="utf-8")
        run_git(["add", "fkst.workspace.toml"], cwd=source, env=env)
        run_git(["commit", "-q", "-m", "integration base"], cwd=source, env=env)
        run_git(["branch", "integration-test"], cwd=source, env=env)
        (source / "fkst.workspace.toml").write_text(self._dev_workspace_text(root / "platform"), encoding="utf-8")
        run_git(["add", "fkst.workspace.toml"], cwd=source, env=env)
        run_git(["commit", "-q", "-m", "advance dev workspace"], cwd=source, env=env)
        run_git(["branch", "dev"], cwd=source, env=env)
        remote = root / name
        run_git(["init", "--bare", "-q", str(remote)], cwd=root, env=env)
        run_git(["remote", "add", "origin", str(remote)], cwd=source, env=env)
        run_git(["push", "-q", "origin", "dev", "integration-test"], cwd=source, env=env)
        return remote

    def _clone_branch(self, remote: Path, checkout: Path, env: dict[str, str]) -> None:
        checkout.parent.mkdir(parents=True, exist_ok=True)
        run_git(["clone", "-q", "--branch", "integration-test", str(remote), str(checkout)], cwd=checkout.parent, env=env)

    def _base_workspace_text(self, platform: Path) -> str:
        return textwrap.dedent(
            f"""\
            [workspace]
            units = []

            [[external_sources]]
            id = "fkst-packages-platform"
            git = {json.dumps(str(platform))}
            packages = [
              "github-devloop",
              "github-proxy",
              "consensus",
            ]
            """
        )

    def _generated_workspace_text(self, platform: Path, packages: list[str] | None = None) -> str:
        packages = packages or ["github-devloop", "github-proxy", "consensus"]
        return textwrap.dedent(
            f"""\
            [workspace]
            units = []

            [[external_sources]]
            id = "fkst-packages-platform"
            git = {json.dumps(str(platform))}
            packages = {json.dumps(packages)}
            """
        )

    def _dev_workspace_text(self, platform: Path) -> str:
        return textwrap.dedent(
            f"""\
            [workspace]
            units = ["packages/*"]

            [[external_sources]]
            id = "fkst-packages-platform"
            git = {json.dumps(str(platform))}
            packages = [
              "github-devloop",
              "github-proxy",
              "consensus",
            ]
            """
        )


if __name__ == "__main__":
    unittest.main()
