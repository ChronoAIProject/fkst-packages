#!/usr/bin/env python3
"""Execution tests for scripts/run.sh test-affected."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _robust_rmtree(path: str) -> None:
    """Remove a temp dir, tolerating a transient concurrent writer under .git.

    rmtree is not atomic (scandir -> unlink -> rmdir); if anything writes into a
    directory between its final scandir and rmdir, rmdir fails with ENOTEMPTY.
    The fixture builds a git repo and runs git inside it, so a detached git
    background process (e.g. auto gc / maintenance) briefly repopulating .git is
    the likely writer racing cleanup -- observed only on CI as a non-deterministic
    OSError [Errno 39] Directory not empty: '.git'. Retry until the transient
    writer settles; this is the standard cleanup shape CPython's own
    test.support.rmtree and pip use for exactly this inherent race. On any OSError
    the tree is done only when the *root* is gone: a vanished nested entry can
    raise FileNotFoundError on Python < 3.13 while the root still exists.
    """
    for attempt in range(8):
        try:
            shutil.rmtree(path)
            return
        except OSError:
            if not os.path.exists(path):
                return
            if attempt == 7:
                raise
            time.sleep(0.1)


class TestAffectedHarness:
    def __init__(self) -> None:
        # mkdtemp (not TemporaryDirectory) so cleanup has a single explicit owner
        # via _robust_rmtree. Construction happens before the caller's
        # try/finally: h.close(), so clean up here if any construction step fails.
        self.tmp = tempfile.mkdtemp()
        try:
            self.root = Path(self.tmp) / "repo"
            self.scripts = self.root / "scripts"
            self.log = Path(self.tmp) / "runner.log"
            self.runner = Path(self.tmp) / "runner.sh"
            self.root.mkdir()
            self.scripts.mkdir()
            for name in (
                "run.sh",
                "bin_bootstrap.sh",
                "host_run.sh",
                "host_entry.sh",
                "composed_manifest.sh",
                "composed_conformance.sh",
                "test_parallel.sh",
                "check_repo_intake_routing.py",
                "intake_policy_slots.json",
            ):
                shutil.copy2(REPO_ROOT / "scripts" / name, self.scripts / name)
            test_affected = REPO_ROOT / "scripts" / "test_affected.sh"
            if test_affected.exists():
                shutil.copy2(test_affected, self.scripts / "test_affected.sh")
            self.runner.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$FKST_TEST_AFFECTED_LOG\"\n"
                "exit 0\n",
                encoding="utf-8",
            )
            self.runner.chmod(self.runner.stat().st_mode | stat.S_IXUSR)
            self._init_repo()
        except BaseException:
            _robust_rmtree(self.tmp)
            raise

    def close(self) -> None:
        _robust_rmtree(self.tmp)

    def _git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", *args],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr + result.stdout)
        return result.stdout

    def _write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def _init_repo(self) -> None:
        self._git("init")
        # Deterministic fixture hygiene: forbid git's background auto-maintenance
        # so the repo has no detached gc/maintenance process that could write
        # .git after a foreground git returns. _robust_rmtree is the guarantee
        # against the teardown race; this just removes the most plausible writer.
        self._git("config", "gc.auto", "0")
        self._git("config", "maintenance.auto", "false")
        self._git("config", "user.email", "test@example.com")
        self._git("config", "user.name", "Test Runner")
        self._git("checkout", "-b", "dev")
        self._write("packages/consensus/core.lua", "return {}\n")
        self._write("packages/github-devloop/core.lua", "return {}\n")
        self._write("scripts/helper.sh", "#!/bin/sh\n")
        self._write("README.md", "fixture\n")
        self._git("add", ".")
        self._git("commit", "-m", "initial")
        self._git("checkout", "-b", "integration")
        self._write("libraries/devloop/config.lua", "return {integration = true}\n")
        self._git("add", ".")
        self._git("commit", "-m", "integration ahead")
        self._git("checkout", "-b", "feature")

    def run(self, with_branch_env: bool = True) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        # Scope derives from the worktree's own uncommitted edits, so these env
        # vars must NOT be required; spawned implement/fix codex environments do
        # not carry them. Drop them to assert env-independence (with_branch_env=False).
        env.pop("FKST_DEVLOOP_UPSTREAM_BRANCH", None)
        env.pop("FKST_DEVLOOP_INTEGRATION_BRANCH", None)
        if with_branch_env:
            env["FKST_DEVLOOP_UPSTREAM_BRANCH"] = "dev"
            env["FKST_DEVLOOP_INTEGRATION_BRANCH"] = "integration"
        env["FKST_TEST_AFFECTED_RUNNER"] = str(self.runner)
        env["FKST_TEST_AFFECTED_LOG"] = str(self.log)
        return subprocess.run(
            ["/bin/bash", "scripts/run.sh", "test-affected"],
            cwd=self.root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def runner_args(self) -> list[str]:
        if not self.log.exists():
            return []
        return self.log.read_text(encoding="utf-8").splitlines()


class RunShTestAffectedTest(unittest.TestCase):
    def test_scopes_to_uncommitted_changed_package(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test github-devloop"])
        finally:
            h.close()

    def test_works_without_integration_branch_env(self) -> None:
        # Regression guard (#1619 follow-up): the spawned implement/fix codex
        # environment does NOT carry FKST_DEVLOOP_INTEGRATION_BRANCH. The earlier
        # base-ref derivation fail-closed here, breaking every implement. Scope
        # must derive purely from the worktree's uncommitted edits.
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(with_branch_env=False)

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test github-devloop"])
        finally:
            h.close()

    def test_committed_only_changes_fall_back_to_full(self) -> None:
        # Codex verifies before committing, so its edits are uncommitted at verify
        # time. If nothing is uncommitted (e.g. already committed), fall back to the
        # full suite rather than silently testing nothing.
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {committed = true}\n")
            h._git("add", ".")
            h._git("commit", "-m", "committed change")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test"])
        finally:
            h.close()

    def test_runs_full_for_broad_paths(self) -> None:
        broad_paths = (
            "libraries/devloop/extra.lua",
            "scripts/helper.sh",
            ".github/workflows/ci.yml",
            "fkst.workspace.toml",
        )
        for rel in broad_paths:
            h = TestAffectedHarness()
            try:
                h._write(rel, "changed\n")

                result = h.run()

                self.assertEqual(result.returncode, 0, rel + "\n" + result.stderr + result.stdout)
                self.assertEqual(h.runner_args(), ["test"], rel)
            finally:
                h.close()

    def test_runs_full_for_dogfood_operator_paths(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write(".claude/skills/dogfood-github-devloop/dogfood.sh", "#!/usr/bin/env bash\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test"])
        finally:
            h.close()

    def test_runs_each_changed_package(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/consensus/core.lua", "return {changed = true}\n")
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test consensus", "test github-devloop"])
        finally:
            h.close()

    def test_untracked_new_package_file_is_counted(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/new_module.lua", "return {}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test github-devloop"])
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
