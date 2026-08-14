#!/usr/bin/env python3
"""Tests for producer-owned exit typing of repository unittest units."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RUNNER = REPO_ROOT / "scripts" / "run_typed_unittest.py"


class TypedUnittestRunnerTest(unittest.TestCase):
    def run_fixture(self, source: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="fkst-typed-unittest-") as tmp:
            fixture = Path(tmp) / "fixture_test.py"
            fixture.write_text(textwrap.dedent(source), encoding="utf-8")
            return subprocess.run(
                [sys.executable, "-B", str(RUNNER), str(fixture)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_completed_passing_suite_returns_zero(self) -> None:
        result = self.run_fixture(
            """
            import unittest

            class FixtureTest(unittest.TestCase):
                def test_passes(self):
                    self.assertTrue(True)
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_completed_failing_suite_returns_typed_semantic_exit(self) -> None:
        result = self.run_fixture(
            """
            import unittest

            class FixtureTest(unittest.TestCase):
                def test_fails(self):
                    self.fail("deterministic repository failure")
            """
        )

        self.assertEqual(result.returncode, 10, result.stderr + result.stdout)
        self.assertIn("FAILED (failures=1)", result.stderr)

    def test_completed_suite_error_remains_untyped(self) -> None:
        result = self.run_fixture(
            """
            import unittest

            class FixtureTest(unittest.TestCase):
                def test_errors(self):
                    raise RuntimeError("deterministic test error")
            """
        )

        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertIn("FAILED (errors=1)", result.stderr)

    def test_mixed_failure_and_error_remains_untyped(self) -> None:
        result = self.run_fixture(
            """
            import unittest

            class FixtureTest(unittest.TestCase):
                def test_fails(self):
                    self.fail("deterministic repository failure")

                def test_errors(self):
                    raise RuntimeError("unattributed test error")
            """
        )

        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertIn("FAILED (failures=1, errors=1)", result.stderr)

    def test_import_failure_remains_untyped(self) -> None:
        result = self.run_fixture('raise RuntimeError("import failed")\n')

        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertIn("import failed", result.stderr)

    def test_empty_suite_returns_typed_configuration_exit(self) -> None:
        result = self.run_fixture("VALUE = 1\n")

        self.assertEqual(result.returncode, 11, result.stderr + result.stdout)
        self.assertIn("discovered no tests", result.stderr)


if __name__ == "__main__":
    unittest.main()
