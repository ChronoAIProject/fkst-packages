import json
import tempfile
import unittest
from pathlib import Path

import build_test_failure_set as subject


BASE_SHA = "a" * 40
HEAD_SHA = "b" * 40
TESTED_SHA = "c" * 40
PASS_RESULT = "FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE"
FAIL_RESULT = "FKST_LOCAL_ITERATION_RESULT:v2:FAIL:SEMANTIC"


def report(owner: str, name: str, status: str) -> dict:
    failed = 1 if status == "fail" else 0
    return {
        "schema": "fkst.test.report.v1",
        "summary": {"passed": 1 - failed, "failed": failed},
        "tests": [
            {
                "owner_namespace": owner,
                "file": "tests/example_test.lua",
                "name": name,
                "status": status,
            }
        ],
    }


class BuildFailureSetTest(unittest.TestCase):
    def test_pull_request_manifest_preserves_commit_and_run_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            reports = root / "reports"
            reports.mkdir()
            (reports / "pkg.json").write_text(
                json.dumps(report("pkg", "test_same_failure", "fail")),
                encoding="utf-8",
            )
            event = root / "event.json"
            event.write_text(
                json.dumps(
                    {
                        "pull_request": {
                            "base": {"sha": BASE_SHA},
                            "head": {"sha": HEAD_SHA},
                        }
                    }
                ),
                encoding="utf-8",
            )

            manifest = subject.build_manifest(
                repo_root=root,
                report_dir=reports,
                repository="owner/repo",
                workflow_run_id="202",
                workflow_run_attempt=3,
                event_name="pull_request",
                event_path=event,
                tested_commit=TESTED_SHA,
                local_iteration_result=FAIL_RESULT,
                expected_reports=["pkg.json"],
            )

            self.assertEqual(manifest["schema"], "fkst.test.failure-set.v1")
            self.assertTrue(manifest["complete"])
            self.assertEqual(manifest["repository"], "owner/repo")
            self.assertEqual(manifest["workflow_run_id"], "202")
            self.assertEqual(manifest["workflow_run_attempt"], 3)
            self.assertEqual(manifest["tested_commit"], TESTED_SHA)
            self.assertEqual(manifest["base_commit"], BASE_SHA)
            self.assertEqual(manifest["head_commit"], HEAD_SHA)
            self.assertEqual(manifest["failures"][0]["name"], "test_same_failure")

    def test_missing_expected_report_is_explicitly_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            reports = root / "reports"
            reports.mkdir()
            event = root / "event.json"
            event.write_text(json.dumps({"after": BASE_SHA}), encoding="utf-8")

            manifest = subject.build_manifest(
                repo_root=root,
                report_dir=reports,
                repository="owner/repo",
                workflow_run_id="101",
                workflow_run_attempt=1,
                event_name="push",
                event_path=event,
                tested_commit=BASE_SHA,
                local_iteration_result=PASS_RESULT,
                expected_reports=["pkg.json"],
            )

            self.assertFalse(manifest["complete"])
            self.assertIn("report-inventory-mismatch", manifest["incomplete_reasons"])

    def test_unreported_failure_makes_the_failure_set_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            reports = root / "reports"
            reports.mkdir()
            (reports / "pkg.json").write_text(
                json.dumps(report("pkg", "test_green", "pass")),
                encoding="utf-8",
            )
            event = root / "event.json"
            event.write_text(json.dumps({"after": BASE_SHA}), encoding="utf-8")

            manifest = subject.build_manifest(
                repo_root=root,
                report_dir=reports,
                repository="owner/repo",
                workflow_run_id="101",
                workflow_run_attempt=1,
                event_name="push",
                event_path=event,
                tested_commit=BASE_SHA,
                local_iteration_result=FAIL_RESULT,
                expected_reports=["pkg.json"],
            )

            self.assertFalse(manifest["complete"])
            self.assertIn("local-result-report-mismatch", manifest["incomplete_reasons"])

    def test_green_full_run_establishes_a_complete_empty_failure_set(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            reports = root / "reports"
            reports.mkdir()
            (reports / "pkg.json").write_text(
                json.dumps(report("pkg", "test_green", "pass")),
                encoding="utf-8",
            )
            event = root / "event.json"
            event.write_text(json.dumps({"after": BASE_SHA}), encoding="utf-8")

            manifest = subject.build_manifest(
                repo_root=root,
                report_dir=reports,
                repository="owner/repo",
                workflow_run_id="101",
                workflow_run_attempt=1,
                event_name="push",
                event_path=event,
                tested_commit=BASE_SHA,
                local_iteration_result=PASS_RESULT,
                expected_reports=["pkg.json"],
            )

            self.assertTrue(manifest["complete"])
            self.assertEqual(manifest["failures"], [])
            self.assertEqual(manifest["report_count"], 1)
            self.assertEqual(manifest["expected_report_count"], 1)
            self.assertEqual(manifest["local_iteration_result"], "PASS:NONE")

    def test_nonsemantic_local_result_is_explicitly_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            reports = root / "reports"
            reports.mkdir()
            (reports / "pkg.json").write_text(
                json.dumps(report("pkg", "test_failure", "fail")),
                encoding="utf-8",
            )
            event = root / "event.json"
            event.write_text(json.dumps({"after": BASE_SHA}), encoding="utf-8")

            manifest = subject.build_manifest(
                repo_root=root,
                report_dir=reports,
                repository="owner/repo",
                workflow_run_id="101",
                workflow_run_attempt=1,
                event_name="push",
                event_path=event,
                tested_commit=BASE_SHA,
                local_iteration_result="FKST_LOCAL_ITERATION_RESULT:v2:UNKNOWN:UNKNOWN",
                expected_reports=["pkg.json"],
            )

            self.assertFalse(manifest["complete"])
            self.assertIn("local-result-not-comparable", manifest["incomplete_reasons"])


if __name__ == "__main__":
    unittest.main()
