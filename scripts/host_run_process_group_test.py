#!/usr/bin/env python3
"""Tests for bounded host-run process-group cleanup."""

from __future__ import annotations

import signal
import unittest
from unittest import mock

import host_run_test_support as subject


class FakeProcess:
    pid = 123

    def __init__(self, status: int | None) -> None:
        self.status = status

    def poll(self) -> int | None:
        return self.status


class ProcessGroupCleanupTest(unittest.TestCase):
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
