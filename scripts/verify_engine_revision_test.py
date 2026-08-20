#!/usr/bin/env python3
"""Behavior tests for the verification engine revision subject."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VERIFY = REPO_ROOT / "scripts" / "verify_engine_revision.py"


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout.strip()


class RevisionSubjectHarness:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        git(self.root, "init", "--quiet")
        git(self.root, "config", "user.email", "test@example.invalid")
        git(self.root, "config", "user.name", "Test User")
        git(self.root, "branch", "-M", "base")
        self.write_pin("1111111111111111111111111111111111111111")
        git(self.root, "add", ".fkst/substrate-ref")
        git(self.root, "commit", "--quiet", "-m", "initial pin")
        git(self.root, "switch", "--quiet", "-c", "feature")
        git(self.root, "switch", "--quiet", "base")
        self.write_pin("2222222222222222222222222222222222222222")
        git(self.root, "add", ".fkst/substrate-ref")
        git(self.root, "commit", "--quiet", "-m", "advance base pin")
        git(self.root, "switch", "--quiet", "feature")

    def close(self) -> None:
        self.tmp.cleanup()

    def write_pin(self, pin: str) -> None:
        path = self.root / ".fkst" / "substrate-ref"
        path.parent.mkdir(exist_ok=True)
        path.write_text(pin + "\n", encoding="utf-8")

    def verify(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(VERIFY), "--repo-root", str(self.root), "--base-ref", "base"],
            cwd=self.root,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


class VerifyEngineRevisionTest(unittest.TestCase):
    def test_inherited_stale_pin_fails_verification(self) -> None:
        harness = RevisionSubjectHarness()
        try:
            result = harness.verify()

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("inherited stale engine pin", result.stderr)
            self.assertIn("head=1111111111111111111111111111111111111111", result.stderr)
            self.assertIn("base=2222222222222222222222222222222222222222", result.stderr)
        finally:
            harness.close()

    def test_explicit_head_pin_transition_is_the_verification_subject(self) -> None:
        harness = RevisionSubjectHarness()
        try:
            declared = "3333333333333333333333333333333333333333"
            harness.write_pin(declared)

            uncommitted = harness.verify()

            self.assertNotEqual(uncommitted.returncode, 0)
            self.assertIn("head=1111111111111111111111111111111111111111", uncommitted.stderr)

            git(harness.root, "add", ".fkst/substrate-ref")
            git(harness.root, "commit", "--quiet", "-m", "declare engine transition")
            committed = harness.verify()

            self.assertEqual(committed.returncode, 0, committed.stderr)
            self.assertIn(f"engine revision subject: head={declared}", committed.stdout)
            self.assertIn("base=2222222222222222222222222222222222222222", committed.stdout)
        finally:
            harness.close()


if __name__ == "__main__":
    unittest.main()
