#!/usr/bin/env python3
"""Unit tests for GitHub Actions workflow contracts."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


def ci_workflow_source() -> str:
    return (Path(__file__).resolve().parents[1] / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")


def workflow_step_block(source: str, name: str) -> str:
    match = re.search(rf"(?ms)^      - name: {re.escape(name)}\n(?P<body>.*?)(?=^      - name: |\Z)", source)
    if match is None:
        raise AssertionError(f"missing workflow step: {name}")
    return match.group("body")


class CiWorkflowContractTest(unittest.TestCase):
    def test_dev_ref_fetch_uses_remote_tracking_ref(self) -> None:
        step = workflow_step_block(ci_workflow_source(), "Ensure dev ref is available")

        self.assertIn("git fetch origin refs/heads/dev:refs/remotes/origin/dev", step)
        self.assertIn("git rev-parse --verify origin/dev", step)
        self.assertNotIn("git fetch origin dev:dev", step)
        self.assertNotIn(":refs/heads/dev", step)


if __name__ == "__main__":
    unittest.main()
