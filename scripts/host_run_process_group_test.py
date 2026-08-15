#!/usr/bin/env python3
"""Tests for bounded host-run process-group cleanup."""

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import host_run_test_support as subject
from host_run_test_support import run_bounded


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def wait_for_process_exit(pid: int, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


class FakeProcess:
    pid = 123

    def __init__(self, status: int | None) -> None:
        self.status = status

    def poll(self) -> int | None:
        return self.status


class FakeTimedOutProcess(FakeProcess):
    def __init__(self) -> None:
        super().__init__(None)
        self.communicate_calls = 0

    def communicate(self, timeout: float) -> tuple[str, str]:
        self.communicate_calls += 1
        if self.communicate_calls == 1:
            raise subprocess.TimeoutExpired(["fixture"], timeout)
        self.status = -signal.SIGKILL
        return "", ""


class ProcessGroupCleanupTest(unittest.TestCase):
    def test_bounded_runner_kills_process_tree_on_timeout_and_parent_exit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = root / "child-tree.sh"
            write_executable(
                script,
                "#!/usr/bin/env bash\nsleep 60 >/dev/null 2>&1 &\nprintf '%s %s\\n' \"$$\" \"$!\" > \"$1\"\n[ \"$2\" != timeout ] || wait\n",
            )
            for mode in ("timeout", "success"):
                pid_file = root / f"{mode}.pids"
                pids: list[int] = []
                started_at = time.monotonic()
                try:
                    if mode == "timeout":
                        # Deadline must comfortably exceed the fixture's pid-file write, else under load the
                        # tree is killed before line writes "$1" and the read below FileNotFoundErrors (flake
                        # observed 2026-07-22: 1.0s raced the write under contention). 3.0s stays well under
                        # the <5.0s bound below while giving the sub-second write ample scheduling margin.
                        with self.assertRaises(subprocess.TimeoutExpired):
                            run_bounded(
                                [str(script), str(pid_file), mode],
                                cwd=root,
                                env=os.environ.copy(),
                                timeout=3.0,
                            )
                        self.assertLess(time.monotonic() - started_at, 8.0)
                    else:
                        result = run_bounded(
                            [str(script), str(pid_file), mode], cwd=root, env=os.environ.copy(), timeout=5.0
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                    pids = [int(value) for value in pid_file.read_text(encoding="utf-8").split()]
                    self.assertEqual(len(pids), 2)
                    for pid in pids:
                        self.assertTrue(wait_for_process_exit(pid), f"process {pid} survived {mode} cleanup")
                finally:
                    for pid in pids:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_timeout_cleanup_kills_process_group_once(self) -> None:
        process = FakeTimedOutProcess()
        with mock.patch.object(subject.subprocess, "Popen", return_value=process), mock.patch.object(
            subject,
            "kill_process_group",
        ) as kill_process_group:
            with self.assertRaises(subprocess.TimeoutExpired):
                subject.run_bounded(["fixture"], cwd=subject.Path("."), env={}, timeout=1.0)

        kill_process_group.assert_called_once_with(process)

    def test_permission_error_is_accepted_after_group_disappears(self) -> None:
        process = FakeProcess(-signal.SIGKILL)
        with mock.patch.object(
            subject.os,
            "killpg",
            side_effect=[PermissionError(), ProcessLookupError()],
        ) as killpg:
            subject.kill_process_group(process)  # type: ignore[arg-type]

        self.assertEqual(
            killpg.call_args_list,
            [mock.call(process.pid, signal.SIGKILL), mock.call(process.pid, 0)],
        )

    def test_permission_error_remains_visible_while_group_exists(self) -> None:
        process = FakeProcess(-signal.SIGKILL)
        with mock.patch.object(
            subject.os,
            "killpg",
            side_effect=[PermissionError(), None],
        ):
            with self.assertRaises(PermissionError):
                subject.kill_process_group(process)  # type: ignore[arg-type]


if __name__ == "__main__":
    unittest.main()
