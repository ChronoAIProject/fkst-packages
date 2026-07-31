#!/usr/bin/env python3
"""Behavior tests for dogfood.sh `clean_stale_runtime_worktrees` preserving live worktrees (#2925).

A restart SIGKILLs only the supervise; an in-flight codex is ORPHANED and keeps running against its
worktree (crash-only contract). The cleaner used to `worktree remove --force` the registration and then
`rm -rf` the whole old runtime generation, so the orphan kept writing into a deleted path and recreated a
partial, UNREGISTERED husk. Harvest then ran `cd` into it, exited nonzero WITHOUT a typed marker, and the
run was recorded as a false `impl-failed / local-iteration-attribution-indeterminate` — observed on #2919
and twice on #2925's own implementation.

A registered worktree is the ground truth for "someone still owns this", so these tests pin the three
decisions the cleaner must make. They drive the real shell function against a synthetic git repo and
synthetic generation directories; nothing in the operator's real dogfood state is touched.
"""

from __future__ import annotations

import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DOGFOOD = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh"


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True, capture_output=True, text=True,
    ).stdout


class PruneGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

        self.pkgsrc = self.root / "pkgsrc"
        self.pkgsrc.mkdir()
        _git(self.pkgsrc.parent, "init", "-q", "pkgsrc")
        _git(self.pkgsrc, "config", "user.email", "t@example.com")
        _git(self.pkgsrc, "config", "user.name", "t")
        (self.pkgsrc / "f").write_text("x\n")
        _git(self.pkgsrc, "add", "f")
        _git(self.pkgsrc, "commit", "-qm", "init")

        self.logdir = self.root / "logs"
        self.logdir.mkdir()

        # three generations: current (keep), an old one holding a live registration, an old idle one
        self.keep = self.logdir / "dogfood-rt-packages.300"
        self.held = self.logdir / "dogfood-rt-packages.100"
        self.idle = self.logdir / "dogfood-rt-packages.200"
        for d in (self.keep, self.held, self.idle):
            (d / "worktrees").mkdir(parents=True)
        (self.idle / "scratch.txt").write_text("no registration points here\n")

        # the ONLY registered worktree lives in the old `held` generation — the orphaned-worker case
        self.live_wt = self.held / "worktrees" / "devloop-live"
        _git(self.pkgsrc, "worktree", "add", "-q", "-b", "live", str(self.live_wt))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run_cleaner(self) -> str:
        """Source dogfood.sh with a stub config and invoke only the cleaner."""
        script = textwrap.dedent(f"""
            set -u
            DOGFOOD_ROOT={self.root}
            DOGFOOD_CONFIG=/nonexistent
            export DOGFOOD_ROOT DOGFOOD_CONFIG
            # shellcheck disable=SC1090
            . "{DOGFOOD}" >/dev/null 2>&1 || true
            PKGSRC="{self.pkgsrc}"
            LOGDIR="{self.logdir}"
            clean_stale_runtime_worktrees packages "{self.keep}"
        """)
        return subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True,
        ).stdout

    def test_generation_holding_a_registered_worktree_is_preserved(self) -> None:
        """The orphaned-worker case: its directory and its registration both survive."""
        out = self._run_cleaner()
        self.assertTrue(self.held.is_dir(), "generation holding a live worktree was deleted")
        self.assertTrue(self.live_wt.is_dir(), "live worktree directory was deleted")
        registered = _git(self.pkgsrc, "worktree", "list", "--porcelain")
        self.assertIn(str(self.live_wt), registered, "live worktree registration was removed")
        self.assertIn("preserving", out, "preservation was not reported to the operator")

    def test_generation_without_registrations_is_still_reclaimed(self) -> None:
        """The guard must not turn the cleaner into a no-op — idle generations still go."""
        self._run_cleaner()
        self.assertFalse(self.idle.exists(), "idle old generation was not reclaimed")

    def test_current_generation_is_never_touched(self) -> None:
        self._run_cleaner()
        self.assertTrue(self.keep.is_dir(), "current runtime root was reclaimed")

    def test_generation_is_reclaimed_once_its_registration_is_gone(self) -> None:
        """Reclamation is deferred, not abandoned: the next pass takes it."""
        self._run_cleaner()
        self.assertTrue(self.held.is_dir())
        _git(self.pkgsrc, "worktree", "remove", "--force", str(self.live_wt))
        self._run_cleaner()
        self.assertFalse(self.held.exists(), "generation was not reclaimed after its worker released it")


if __name__ == "__main__":
    unittest.main()
