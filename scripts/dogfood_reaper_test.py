#!/usr/bin/env python3
"""Behavior tests for the dogfood.sh test-process reaper's orphan-depth classification.

Regression guard for the kill-path fix (2026-07-22): the reaper judged orphan-ness at the LEAF
`fkst-framework test` proc, but the leak tree is `init(1) -> orphaned test-harness (the group LEADER,
ppid=1) -> fkst-framework test (leaf)` — so it missed 6 real leaked trees while reporting "1 reaped". It
now judges the process-GROUP LEADER's orphan status. Because that broadens kill eligibility, these tests
pin the classification: a group-leader-orphan tree is a would-reap; a live-parent tree is spared.

Runs the reaper in DOGFOOD_REAP_DRYRUN=1 (reports, never kills) against synthetic process trees this test
builds and tears down. Assertions target THIS test's own synthetic pids/pgids only, so concurrent real
test processes in the suite do not affect the result.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DOGFOOD = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh"

# argv marker so pgrep -f 'fkst-framework test' finds our synthetic leaf; comm stays 'sleep'.
LEAF_ARGV0 = "fkst-framework test --DOGFOOD-REAPER-SELFTEST"


def _spawn_leaf(argv0: str, secs: int) -> None:
    """exec a long sleeper whose argv[0] matches the reaper's pattern (comm='sleep')."""
    os.execvp("sleep", [argv0, str(secs)])  # never returns


def _build_orphan_leader_tree(readfd: int, writefd: int) -> int:
    """init(1) -> orphaned LEADER (setsid, ppid=1) -> leaf(matches pattern). Returns leader pid."""
    inter = os.fork()
    if inter == 0:
        os.close(readfd)
        leader = os.fork()
        if leader == 0:
            os.setsid()  # leader becomes its own session/group leader (pgid == pid)
            leaf = os.fork()
            if leaf == 0:
                os.close(writefd)
                _spawn_leaf(LEAF_ARGV0, 120)
            os.write(writefd, f"{os.getpid()}".encode())  # report leader pid
            os.close(writefd)
            time.sleep(120)  # leader lingers as the orphaned group leader
            os._exit(0)
        os._exit(0)  # intermediate exits -> leader reparents to init (ppid=1)
    os.waitpid(inter, 0)  # reap intermediate
    return int(os.read(readfd, 32).decode())


# NOTE: the reaper also excludes a group leader whose comm is node/codex (a defensive belt-and-suspenders
# beyond the leaf-comm guard, which already spares a codex worker that matches the pattern as the LEAF —
# the common case). That leader-comm branch is not covered by a synthetic test here: a hermetic comm=node
# leader is not achievable on macOS (SIP blocks exec of a copied system binary, and `comm` reflects the
# real binary, not argv[0], so `exec -a` cannot fake it). The branch is observable in production via its
# skip line (`group leader comm=node (codex/node), skip`) for an operator running `doctor`.


def _build_live_parent_tree() -> subprocess.Popen:
    """A leader with a LIVE parent (this test's bash child), leaf matches pattern. Must be spared."""
    script = f'exec -a "{LEAF_ARGV0}" sleep 120'
    # setsid via preexec so the bash is a group leader; its parent (python) stays alive => leader.ppid != 1
    return subprocess.Popen(
        ["/bin/bash", "-c", script],
        preexec_fn=os.setsid,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _run_reaper_dryrun() -> str:
    env = os.environ.copy()
    env["DOGFOOD_REAP_DRYRUN"] = "1"
    env["DOGFOOD_TEST_REAP_MINUTES"] = "0"  # threshold 0 => any age >0s qualifies
    result = subprocess.run(
        ["/bin/bash", "-c", f'source "{DOGFOOD}"\nreap_leaked_test_procs'],
        cwd=str(REPO_ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    return result.stdout + result.stderr


class DogfoodReaperOrphanDepth(unittest.TestCase):
    def test_group_leader_orphan_tree_is_would_reap(self) -> None:
        r, w = os.pipe()
        leader = None
        try:
            leader = _build_orphan_leader_tree(r, w)
            os.close(w)
            os.close(r)
            time.sleep(2)  # age > 0s so it clears the threshold
            # confirm the leader really orphaned to init before asserting classification
            self.assertEqual(os.getpgid(leader), leader, "synthetic leader is not its own group leader")
            out = _run_reaper_dryrun()
            self.assertIn(
                f"pgid {leader}",
                out,
                f"group-leader-orphan tree (leader {leader}) was NOT classified would-reap:\n{out}",
            )
            self.assertIn("would-reap", out)
        finally:
            if leader is not None:
                try:
                    os.killpg(leader, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            for fd in (r, w):
                try:
                    os.close(fd)
                except OSError:
                    pass

    def test_live_parent_tree_is_spared(self) -> None:
        proc = None
        try:
            proc = _build_live_parent_tree()
            leader = proc.pid  # setsid leader; its parent (python) is alive => ppid != 1
            time.sleep(2)
            out = _run_reaper_dryrun()
            # Non-vacuous: the reaper must have SEEN this tree and classified it skip (a skip line names its
            # group) — absence-from-would-reap alone could mean it was never detected.
            self.assertIn(
                f"(group {leader})",
                out,
                f"reaper did not detect the live-parent tree (leader {leader}):\n{out}",
            )
            would_reap_pgids = {
                line.split("pgid")[1].split()[0]
                for line in out.splitlines()
                if "would-reap" in line and "pgid" in line
            }
            self.assertNotIn(
                str(leader),
                would_reap_pgids,
                f"live-parent tree (leader {leader}) was wrongly classified would-reap:\n{out}",
            )
        finally:
            if proc is not None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass


if __name__ == "__main__":
    unittest.main()
