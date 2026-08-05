#!/usr/bin/env python3
"""Shared capability policy for process-control tests."""

from __future__ import annotations

import os
import unittest


def require_process_control_capability(test_case: unittest.TestCase, unavailable_reason: str | None) -> None:
    if unavailable_reason is None:
        return
    if os.environ.get("FKST_REQUIRE_PROCESS_CONTROL_TESTS") == "1":
        test_case.fail(f"required CI process-control assertion cannot run: {unavailable_reason}")
    test_case.skipTest(unavailable_reason)
