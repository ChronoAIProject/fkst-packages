#!/usr/bin/env python3
"""Behavior tests for scripts/run.sh cmd_test bounded-execution watchdog.

Reproduces the test-runner leak class (CLAUDE.md error-cleanup-patrol + harness doctrine): when the
codex/operator parent that launched `scripts/run.sh test` is SIGKILLed, the run does NOT die with it
(SIGKILL neither propagates to children nor fires the EXIT trap), so it orphans to init and hangs
UNBOUNDED (observed 2026-07-22: 6 trees 44min–1h15min old, a real load driver). The prevention makes
that illegal state unrepresentable at the source: arm_test_deadline forks a watchdog that group-kills
the whole run after FKST_TEST_DEADLINE_SECONDS, but ONLY when this shell leads its own process group,
so it never targets a shared/interactive group.

These are black-box tests: they source scripts/run.sh (its main dispatch is source-guarded) and exercise
arm_test_deadline in a real process group, asserting the group self-terminates at the deadline and that
the guard refuses to arm in a shared group.
"""

from __future__ import annotations

import os
import re
import signal
import subprocess
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def _pgid_alive(pgid: int) -> bool:
    """True if any process still belongs to process group pgid."""
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # A process exists in the group but we lack signal permission — still "alive".
        return True


def _reap(pgid: int) -> None:
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


class BoundedTestExecWatchdog(unittest.TestCase):
    def test_orphaned_runaway_run_self_terminates_at_deadline(self) -> None:
        """A run that leads its own group + outlives its parent is group-killed at the deadline.

        This is the leak repro: preexec_fn=os.setsid makes the child a session/group leader (pgid==pid),
        exactly like the codex/dogfood launch path; the child arms a 2s deadline then `sleep 60` (a hung
        run). Without the watchdog the group would live the full 60s (the historic hour-long orphan). With
        it, the group is gone well before 60s.
        """
        script = (
            "source scripts/run.sh\n"
            "FKST_TEST_DEADLINE_SECONDS=2 arm_test_deadline\n"
            "sleep 60\n"
        )
        started = time.time()
        proc = subprocess.Popen(
            ["/bin/bash", "-c", script],
            cwd=str(REPO_ROOT),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            preexec_fn=os.setsid,  # own session => group leader, pgid == pid
        )
        pgid = proc.pid  # leader: pgid == pid
        try:
            # The run leader IS the group leader; the watchdog group-kills the whole tree including the
            # leader. So the leader terminating == the run self-terminated. Poll proc (which also reaps the
            # child, clearing the zombie that would otherwise mask group liveness) within a generous window
            # (deadline 2s + margin), far below the 60s the runaway would otherwise live.
            deadline = time.time() + 20
            while time.time() < deadline:
                if proc.poll() is not None:
                    break
                time.sleep(0.25)
            elapsed = time.time() - started
            self.assertIsNotNone(
                proc.poll(),
                "runaway run survived past the deadline — watchdog did not group-kill it",
            )
            # Prove the WATCHDOG killed it, not an unrelated early exit: SIGKILL, and at (not before) the
            # 2s deadline. An early crash would exit ~instantly with a different code.
            self.assertEqual(
                proc.returncode, -signal.SIGKILL, f"leader exited by {proc.returncode}, not the watchdog's SIGKILL"
            )
            self.assertGreaterEqual(
                elapsed, 1.5, f"exited in {elapsed:.1f}s — before the 2s deadline, so not the watchdog"
            )
            # The whole group must be gone: proc.poll() reaped the leader; any survivor keeps the group alive.
            gone_by = time.time() + 5
            while time.time() < gone_by and _pgid_alive(pgid):
                time.sleep(0.1)
            self.assertFalse(_pgid_alive(pgid), "group members survived the watchdog group-kill")
        finally:
            _reap(pgid)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

    def test_does_not_arm_in_a_shared_group(self) -> None:
        """The guard refuses to arm when this shell is NOT its own group leader.

        No preexec_fn => the child shares the test runner's process group and is not the leader. Arming
        there would group-kill a shared/interactive group (the user's shell). arm_test_deadline must
        no-op: TEST_DEADLINE_WATCHDOG stays empty and the process survives past the deadline.
        """
        script = (
            "source scripts/run.sh\n"
            "FKST_TEST_DEADLINE_SECONDS=1 arm_test_deadline\n"
            'echo "ARMED=[${TEST_DEADLINE_WATCHDOG}]"\n'
            "sleep 3\n"
            'echo REACHED_END\n'
        )
        result = subprocess.run(
            ["/bin/bash", "-c", script],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertIn("ARMED=[]", result.stdout, f"watchdog armed in a shared group: {result.stdout!r}")
        self.assertIn(
            "REACHED_END",
            result.stdout,
            f"process was killed in a shared group despite the guard: {result.stdout!r}",
        )

    def test_disarm_stops_the_watchdog_on_normal_exit(self) -> None:
        """disarm_test_deadline kills the watchdog so a normal finish leaves nothing running.

        Arm with a long deadline in an own-group shell, capture the watchdog pid, disarm, and assert the
        watchdog process is gone — the prevention must not itself leak a lingering sleeper.
        """
        script = (
            "source scripts/run.sh\n"
            "FKST_TEST_DEADLINE_SECONDS=600 arm_test_deadline\n"
            'WD="$TEST_DEADLINE_WATCHDOG"\n'  # capture before disarm clears it (run.sh runs under set -u)
            'SLEEP="$(pgrep -P "$WD" 2>/dev/null || true)"\n'  # the watchdog subshell's sleep child
            'echo "WD=$WD SLEEP=$SLEEP"\n'
            "disarm_test_deadline\n"
            "sleep 0.5\n"
            'wd=GONE; kill -0 "$WD" 2>/dev/null && wd=ALIVE\n'
            'sl=GONE; [ -n "$SLEEP" ] && kill -0 "$SLEEP" 2>/dev/null && sl=ALIVE\n'
            'echo "WATCHDOG=$wd SLEEP_CHILD=$sl"\n'
        )
        result = subprocess.run(
            ["/bin/bash", "-c", script],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=30,
            preexec_fn=os.setsid,
        )
        # Non-vacuous: the watchdog must have actually armed (a real subshell pid) and its sleep child must
        # have been observed — else "GONE" below would pass trivially for a never-armed/never-found target.
        m = re.search(r"WD=(\d+) SLEEP=(\d+)", result.stdout)
        self.assertIsNotNone(
            m, f"watchdog did not arm / sleep child not captured: {result.stdout!r} / {result.stderr!r}"
        )
        self.assertIn(
            "WATCHDOG=GONE",
            result.stdout,
            f"disarm did not stop the watchdog: {result.stdout!r} / {result.stderr!r}",
        )
        # The sleep child must die too — else a normal finish leaves an orphaned timer that fires a stale
        # kill -9 -pgid up to the deadline later on a possibly-reused pgid (the disarm-subtree fix).
        self.assertIn(
            "SLEEP_CHILD=GONE",
            result.stdout,
            f"disarm left the watchdog's sleep child orphaned: {result.stdout!r} / {result.stderr!r}",
        )


if __name__ == "__main__":
    unittest.main()
