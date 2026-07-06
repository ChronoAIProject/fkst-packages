#!/usr/bin/env python3
"""Restart drain behavior tests for scripts/host_run.sh."""

from __future__ import annotations

import os
import subprocess
import textwrap
import time
import unittest

from host_run_test import HostRunHarness, kill_if_alive, shell_quote


def descendant_pids(pid: int) -> list[int]:
    result = subprocess.run(
        [
            "python3",
            "-",
            str(pid),
        ],
        input=textwrap.dedent(
            """\
            import subprocess
            import sys

            root = int(sys.argv[1])
            rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
            children = {}
            for row in rows.splitlines():
                parts = row.split()
                if len(parts) < 2:
                    continue
                pid, ppid = int(parts[0]), int(parts[1])
                children.setdefault(ppid, []).append(pid)

            stack = list(children.get(root, []))
            out = []
            while stack:
                child = stack.pop(0)
                out.append(child)
                stack.extend(children.get(child, []))
            print(" ".join(str(item) for item in out))
            """
        ),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    if not result.stdout.strip():
        return []
    return [int(item) for item in result.stdout.split()]


def start_parent_with_child(seconds: int = 30) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        ["/bin/sh", "-c", f"sleep {seconds} >/dev/null 2>&1 & child=$!; wait \"$child\""],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def wait_for_descendant(pid: int, timeout: float = 5.0) -> list[int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        children = descendant_pids(pid)
        if children:
            return children
        time.sleep(0.02)
    return []


def wait_for_popen_exit(proc: subprocess.Popen[bytes], timeout: float = 5.0) -> bool:
    try:
        proc.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        return False


class HostRunRestartDrainTest(unittest.TestCase):
    def test_restart_without_drain_budget_is_the_immediate_path(self) -> None:
        h = HostRunHarness()
        parent = start_parent_with_child()
        children: list[int] = []
        try:
            children = wait_for_descendant(parent.pid)
            self.assertTrue(children, "fake supervised parent did not start a child process")
            h.durable.mkdir()
            (h.durable / ".fkst-supervise.pid").write_text(f"{parent.pid}\n", encoding="utf-8")

            started = time.monotonic()
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    source scripts/host_run.sh
                    host_run_parse_supervise_args --project-root {shell_quote(h.substrate_host)} --platform-root {shell_quote(h.platform)} --platform-packages 'github-proxy' --durable-root {shell_quote(h.durable)} --runtime-root {shell_quote(h.runtime)} --restart
                    host_run_validate_shape
                    host_run_restart_prior
                    """
                )
            )
            elapsed = time.monotonic() - started

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(elapsed, 0.4)
            self.assertTrue(wait_for_popen_exit(parent), f"parent pid {parent.pid} still alive")
            self.assertNotIn("draining prior supervise process tree", result.stderr)
            self.assertIn("killing prior supervise pid", result.stderr)
        finally:
            kill_if_alive(parent.pid)
            for child in children:
                kill_if_alive(child)
            h.close()

    def test_restart_with_no_descendants_does_not_wait_for_drain_budget(self) -> None:
        h = HostRunHarness()
        parent = subprocess.Popen(["sleep", "30"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            h.durable.mkdir()
            (h.durable / ".fkst-supervise.pid").write_text(f"{parent.pid}\n", encoding="utf-8")

            started = time.monotonic()
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    export FKST_HOST_RUN_RESTART_DRAIN_SECONDS=1.0
                    source scripts/host_run.sh
                    host_run_parse_supervise_args --project-root {shell_quote(h.substrate_host)} --platform-root {shell_quote(h.platform)} --platform-packages 'github-proxy' --durable-root {shell_quote(h.durable)} --runtime-root {shell_quote(h.runtime)} --restart
                    host_run_validate_shape
                    host_run_restart_prior
                    """
                )
            )
            elapsed = time.monotonic() - started

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(elapsed, 0.4)
            self.assertTrue(wait_for_popen_exit(parent), f"parent pid {parent.pid} still alive")
            self.assertNotIn("draining prior supervise process tree", result.stderr)
            self.assertIn("killing prior supervise pid", result.stderr)
        finally:
            kill_if_alive(parent.pid)
            h.close()

    def test_restart_drains_live_descendant_until_budget_then_continues_to_sigkill(self) -> None:
        h = HostRunHarness()
        parent = start_parent_with_child()
        children: list[int] = []
        try:
            children = wait_for_descendant(parent.pid)
            self.assertTrue(children, "fake supervised parent did not start a child process")
            h.durable.mkdir()
            (h.durable / ".fkst-supervise.pid").write_text(f"{parent.pid}\n", encoding="utf-8")

            started = time.monotonic()
            result = h.run_helper(
                textwrap.dedent(
                    f"""\
                    set -euo pipefail
                    export FKST_HOST_RUN_RESTART_DRAIN_SECONDS=0.2
                    source scripts/host_run.sh
                    host_run_parse_supervise_args --project-root {shell_quote(h.substrate_host)} --platform-root {shell_quote(h.platform)} --platform-packages 'github-proxy' --durable-root {shell_quote(h.durable)} --runtime-root {shell_quote(h.runtime)} --restart
                    host_run_validate_shape
                    host_run_restart_prior
                    """
                )
            )
            elapsed = time.monotonic() - started

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreaterEqual(elapsed, 0.18)
            self.assertLess(elapsed, 2.0)
            self.assertTrue(wait_for_popen_exit(parent), f"parent pid {parent.pid} still alive")
            self.assertFalse((h.durable / ".fkst-supervise.pid").exists())
            self.assertIn(f"draining prior supervise process tree pid {parent.pid}", result.stderr)
            self.assertIn("budget=0.2s", result.stderr)
            self.assertIn("drain budget expired", result.stderr)
            self.assertIn("killing prior supervise pid", result.stderr)
        finally:
            kill_if_alive(parent.pid)
            for child in children:
                kill_if_alive(child)
            h.close()


if __name__ == "__main__":
    unittest.main()
