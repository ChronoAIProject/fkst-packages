#!/usr/bin/env python3
"""Tests for bounded host-run process-group cleanup."""

from __future__ import annotations

import signal
import subprocess
import unittest
from pathlib import Path
from unittest import mock

import host_run_test_support as subject


class FakeProcess:
    pid = 123

    def __init__(self, status: int | None) -> None:
        self.status = status

    def poll(self) -> int | None:
        return self.status


class FakeTimedOutProcess:
    pid = 123
    returncode = -signal.SIGKILL

    def __init__(self) -> None:
        self.communicate_calls = 0

    def communicate(self, timeout: float) -> tuple[str, str]:
        self.communicate_calls += 1
        if self.communicate_calls == 1:
            raise subprocess.TimeoutExpired(["fixture"], timeout)
        return "", ""


class ProcessGroupCleanupTest(unittest.TestCase):
    def test_timeout_attempts_process_group_cleanup_once(self) -> None:
        process = FakeTimedOutProcess()
        with mock.patch.object(subject.subprocess, "Popen", return_value=process), mock.patch.object(
            subject, "kill_process_group"
        ) as cleanup:
            with self.assertRaises(subprocess.TimeoutExpired):
                subject.run_bounded(
                    ["fixture"],
                    cwd=Path("."),
                    env={},
                    timeout=1.0,
                )

        cleanup.assert_called_once_with(process)
        self.assertEqual(process.communicate_calls, 2)

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
