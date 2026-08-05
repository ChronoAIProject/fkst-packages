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
import sys
import tempfile
import time
import unittest
from pathlib import Path

from process_control_test_support import require_process_control_capability

REPO_ROOT = Path(__file__).resolve().parents[1]
DOGFOOD = REPO_ROOT / ".claude" / "skills" / "dogfood-github-devloop" / "dogfood.sh"

# argv marker so pgrep -f 'fkst-framework test' finds our synthetic leaf; comm stays 'sleep'.
LEAF_ARGV0 = "fkst-framework test --DOGFOOD-REAPER-SELFTEST"


def _run_selected_tests_with_blind_commands(
    test_names: tuple[str, ...], blind_commands: tuple[str, ...]
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        fixture_bin = Path(tmp)
        for command in blind_commands:
            command_path = fixture_bin / command
            command_path.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            command_path.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{fixture_bin}{os.pathsep}{env['PATH']}"
        env.pop("FKST_REQUIRE_PROCESS_CONTROL_TESTS", None)
        return subprocess.run(
            [sys.executable, "-B", __file__, "-v", *test_names],
            cwd=str(REPO_ROOT),
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )


def _process_field(pid: int, field: str) -> str | None:
    result = subprocess.run(
        ["ps", "-o", f"{field}=", "-p", str(pid)],
        capture_output=True,
        text=True,
        timeout=10,
    )
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        return None
    return value


def _reaper_observation_unavailable_reason(pid: int, leader: int, expected_leader_ppid: int) -> str | None:
    matches = subprocess.run(
        ["pgrep", "-f", "--", LEAF_ARGV0],
        capture_output=True,
        text=True,
        timeout=10,
    )
    observed = {int(line) for line in matches.stdout.splitlines() if line.isdigit()}
    if matches.returncode != 0 or pid not in observed:
        return "synthetic test process is not observable via `pgrep -f -- <pattern>`"

    fields = {
        "comm": _process_field(pid, "comm"),
        "etime": _process_field(pid, "etime"),
        "pgid": _process_field(pid, "pgid"),
        "leader_comm": _process_field(leader, "comm"),
        "leader_ppid": _process_field(leader, "ppid"),
    }
    if any(value is None for value in fields.values()):
        return "synthetic test process is not observable via `ps`"
    if fields["pgid"] != str(leader) or fields["leader_ppid"] != str(expected_leader_ppid):
        return "synthetic test process relationships are not observable via `ps`"
    return None


def _spawn_leaf(argv0: str, secs: int) -> None:
    """exec a long sleeper whose argv[0] matches the reaper's pattern (comm='sleep')."""
    os.execvp("sleep", [argv0, str(secs)])  # never returns


def _build_orphan_leader_tree(readfd: int, writefd: int) -> tuple[int, int]:
    """Build init(1) -> orphaned leader -> matching leaf and return both pids."""
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
            os.write(writefd, f"{os.getpid()} {leaf}".encode())
            os.close(writefd)
            time.sleep(120)  # leader lingers as the orphaned group leader
            os._exit(0)
        os._exit(0)  # intermediate exits -> leader reparents to init (ppid=1)
    os.waitpid(inter, 0)  # reap intermediate
    leader, leaf = os.read(readfd, 64).decode().split()
    return int(leader), int(leaf)


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
            leader, leaf = _build_orphan_leader_tree(r, w)
            os.close(w)
            os.close(r)
            time.sleep(2)  # age > 0s so it clears the threshold
            require_process_control_capability(
                self,
                _reaper_observation_unavailable_reason(leaf, leader, expected_leader_ppid=1),
            )
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
            require_process_control_capability(
                self,
                _reaper_observation_unavailable_reason(leader, leader, expected_leader_ppid=os.getpid()),
            )
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


class ProcessCapabilitySelection(unittest.TestCase):
    def test_ps_blindness_skips_both_reaper_assertions(self) -> None:
        result = _run_selected_tests_with_blind_commands(
            (
                "DogfoodReaperOrphanDepth.test_group_leader_orphan_tree_is_would_reap",
                "DogfoodReaperOrphanDepth.test_live_parent_tree_is_spared",
            ),
            ("ps",),
        )

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("test_group_leader_orphan_tree_is_would_reap", output)
        self.assertIn("test_live_parent_tree_is_spared", output)
        self.assertEqual(output.count("skipped 'synthetic test process is not observable via `ps`'"), 2)


if __name__ == "__main__":
    unittest.main()
