#!/usr/bin/env python3
"""Tests for provenance-bound test failure manifests."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_failure_manifest import build_manifest  # noqa: E402


BASE_SHA = "a" * 40
HEAD_SHA = "b" * 40
CANDIDATE_SHA = "c" * 40


class TestFailureManifest(unittest.TestCase):
    def write_report(self, root: Path, name: str, failures: list[tuple[str, str, str]]) -> None:
        tests = [
            {
                "owner_namespace": owner,
                "file": file_name,
                "name": test_name,
                "status": "fail",
                "error": "diagnostic text is not identity",
            }
            for owner, file_name, test_name in failures
        ]
        (root / name).write_text(
            json.dumps(
                {
                    "schema": "fkst.test.report.v1",
                    "summary": {"passed": 0, "failed": len(tests)},
                    "tests": tests,
                }
            ),
            encoding="utf-8",
        )

    def build(self, root: Path, tested_commit: str) -> dict[str, object]:
        return build_manifest(
            report_dir=root,
            expected_reports=[("pkg", "pkg.json")],
            completed_units={"pkg"},
            observed_failure_units=1,
            tested_commit=tested_commit,
            base_commit=BASE_SHA,
            head_commit=HEAD_SHA,
            event_name="pull_request",
        )

    def test_same_producer_identity_is_byte_identical_across_commits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_report(root, "pkg.json", [("pkg", "tests/example_test.lua", "test_fails")])

            first = self.build(root, CANDIDATE_SHA)
            second = self.build(root, "d" * 40)

            self.assertTrue(first["complete"])
            self.assertEqual(
                json.dumps(first["failures"], sort_keys=True, separators=(",", ":")),
                json.dumps(second["failures"], sort_keys=True, separators=(",", ":")),
            )

    def test_missing_expected_report_marks_manifest_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            manifest = build_manifest(
                report_dir=Path(tmp),
                expected_reports=[("pkg", "pkg.json")],
                completed_units={"pkg"},
                observed_failure_units=1,
                tested_commit=CANDIDATE_SHA,
                base_commit=BASE_SHA,
                head_commit=HEAD_SHA,
                event_name="pull_request",
            )

            self.assertFalse(manifest["complete"])
            self.assertIn("missing-report:pkg.json", manifest["incomplete_reasons"])

    def test_nonsemantic_failure_unit_marks_manifest_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_report(root, "pkg.json", [])

            manifest = build_manifest(
                report_dir=root,
                expected_reports=[("pkg", "pkg.json")],
                completed_units={"pkg"},
                observed_failure_units=1,
                tested_commit=CANDIDATE_SHA,
                base_commit=BASE_SHA,
                head_commit=HEAD_SHA,
                event_name="pull_request",
            )

            self.assertFalse(manifest["complete"])
            self.assertIn("failure-unit-count-mismatch", manifest["incomplete_reasons"])


if __name__ == "__main__":
    unittest.main()
