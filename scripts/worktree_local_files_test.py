#!/usr/bin/env python3
"""Behavior tests for host-owned worktree local-file hydration."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "hydrate_worktree_local_files.py"


class WorktreeLocalFilesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.host = self.root / "host"
        self.worktree = self.root / "worktree"
        self.host.mkdir()
        self.run_git(self.host, "init", "-b", "dev")
        self.run_git(self.host, "config", "user.name", "FKST Test")
        self.run_git(self.host, "config", "user.email", "fkst@example.invalid")
        (self.host / ".gitignore").write_text(
            ".env.local\nconfig/*.local\n",
            encoding="utf-8",
        )
        self.run_git(self.host, "add", ".gitignore")
        self.run_git(self.host, "commit", "-m", "Initialize fixture")
        self.run_git(self.host, "worktree", "add", "-b", "feature", str(self.worktree))

    def run_git(self, cwd: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=cwd,
            check=True,
            capture_output=True,
            text=True,
        )

    def run_hydration(self, paths: str | None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        if paths is None:
            env.pop("FKST_WORKTREE_LOCAL_FILES", None)
        else:
            env["FKST_WORKTREE_LOCAL_FILES"] = paths
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--source-root",
                str(self.host),
                "--worktree",
                str(self.worktree),
            ],
            env=env,
            capture_output=True,
            text=True,
        )

    def test_copies_declared_ignored_files_and_refreshes_stale_targets(self) -> None:
        (self.host / ".env.local").write_text("first=value\n", encoding="utf-8")
        (self.host / "config").mkdir()
        (self.host / "config" / "frontend.local").write_text("second=value\n", encoding="utf-8")
        (self.worktree / ".env.local").write_text("stale=value\n", encoding="utf-8")

        result = self.run_hydration(".env.local\nconfig/frontend.local")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.worktree / ".env.local").read_text(encoding="utf-8"), "first=value\n")
        self.assertEqual(
            (self.worktree / "config" / "frontend.local").read_text(encoding="utf-8"),
            "second=value\n",
        )
        self.assertNotIn("first=value", result.stdout + result.stderr)

    def test_unset_configuration_is_a_no_op(self) -> None:
        result = self.run_hydration(None)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.worktree.glob("*.local")), [])

    def test_rejects_absolute_parent_git_and_duplicate_paths(self) -> None:
        invalid_values = [
            "/tmp/.env.local",
            "../.env.local",
            ".git/config",
            ".env.local\n.env.local",
        ]
        for value in invalid_values:
            with self.subTest(value=value):
                result = self.run_hydration(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("error: worktree local-file hydration failed:", result.stderr)

    def test_rejects_missing_directories_and_non_ignored_files(self) -> None:
        (self.host / "directory.local").mkdir()
        (self.host / "tracked.txt").write_text("tracked\n", encoding="utf-8")
        self.run_git(self.host, "add", "tracked.txt")
        self.run_git(self.host, "commit", "-m", "Add tracked fixture")

        for value in ["missing.local", "directory.local", "tracked.txt"]:
            with self.subTest(value=value):
                result = self.run_hydration(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("error: worktree local-file hydration failed:", result.stderr)

    def test_preflights_every_path_before_copying_any_file(self) -> None:
        (self.host / ".env.local").write_text("secret=value\n", encoding="utf-8")
        (self.host / "tracked.txt").write_text("tracked\n", encoding="utf-8")
        self.run_git(self.host, "add", "tracked.txt")
        self.run_git(self.host, "commit", "-m", "Add tracked fixture")

        result = self.run_hydration(".env.local\ntracked.txt")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("error: worktree local-file hydration failed:", result.stderr)
        self.assertFalse((self.worktree / ".env.local").exists())

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are required")
    def test_rejects_source_symlinks_that_escape_the_host_root(self) -> None:
        outside = self.root / "outside.local"
        outside.write_text("outside=value\n", encoding="utf-8")
        os.symlink(outside, self.host / ".env.local")

        result = self.run_hydration(".env.local")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("error: worktree local-file hydration failed:", result.stderr)
        self.assertFalse((self.worktree / ".env.local").exists())


if __name__ == "__main__":
    unittest.main()
