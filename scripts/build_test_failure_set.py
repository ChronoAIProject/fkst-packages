#!/usr/bin/env python3
"""Build the producer-owned CI failure-set manifest from structured test reports."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Iterable


FAILURE_SET_SCHEMA = "fkst.test.failure-set.v1"
REPORT_SCHEMA = "fkst.test.report.v1"
RESULT_PREFIX = "FKST_LOCAL_ITERATION_RESULT:v2:"
EXACT_OID = re.compile(r"[0-9a-fA-F]{40}")
NUMERIC = re.compile(r"[0-9]+")


def _exact_oid(value: object) -> bool:
    return isinstance(value, str) and EXACT_OID.fullmatch(value) is not None


def _dense_list(value: object) -> bool:
    return isinstance(value, list)


def _normalize_result(value: str) -> str:
    text = value.strip()
    if text.startswith(RESULT_PREFIX):
        text = text[len(RESULT_PREFIX) :]
    return text


def _event_provenance(event_name: str, event_path: Path, reasons: list[str]) -> dict[str, str]:
    try:
        event = json.loads(event_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        reasons.append("event-payload-invalid")
        return {}
    if not isinstance(event, dict):
        reasons.append("event-payload-invalid")
        return {}
    if event_name == "pull_request":
        pull_request = event.get("pull_request")
        base = pull_request.get("base") if isinstance(pull_request, dict) else None
        head = pull_request.get("head") if isinstance(pull_request, dict) else None
        base_commit = base.get("sha") if isinstance(base, dict) else None
        head_commit = head.get("sha") if isinstance(head, dict) else None
        if not _exact_oid(base_commit) or not _exact_oid(head_commit):
            reasons.append("pull-request-commit-binding-missing")
            return {}
        return {
            "base_commit": str(base_commit).lower(),
            "head_commit": str(head_commit).lower(),
        }
    if event_name == "push":
        return {}
    reasons.append("event-not-comparable")
    return {}


def _failure_identity(test: dict[str, object]) -> tuple[str, str, str] | None:
    fields = (test.get("owner_namespace"), test.get("file"), test.get("name"))
    if not all(isinstance(value, str) and value for value in fields):
        return None
    return fields  # type: ignore[return-value]


def _read_report(path: Path) -> tuple[list[dict[str, str]] | None, str | None]:
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None, "failure-report-json-invalid"
    if not isinstance(report, dict) or report.get("schema") != REPORT_SCHEMA:
        return None, "failure-report-invalid"
    summary = report.get("summary")
    tests = report.get("tests")
    if not isinstance(summary, dict) or not _dense_list(tests):
        return None, "failure-report-invalid"
    passed = summary.get("passed")
    failed = summary.get("failed")
    if (
        not isinstance(passed, int)
        or isinstance(passed, bool)
        or passed < 0
        or not isinstance(failed, int)
        or isinstance(failed, bool)
        or failed < 0
    ):
        return None, "failure-report-invalid"

    observed_passed = 0
    observed_failed = 0
    failures: list[dict[str, str]] = []
    for test in tests:
        if not isinstance(test, dict) or test.get("status") not in {"pass", "fail"}:
            return None, "failure-report-test-invalid"
        identity = _failure_identity(test)
        if identity is None:
            return None, "failure-report-test-invalid"
        if test["status"] == "pass":
            observed_passed += 1
        else:
            observed_failed += 1
            failures.append(
                {"owner_namespace": identity[0], "file": identity[1], "name": identity[2]}
            )
    if observed_passed != passed or observed_failed != failed:
        return None, "failure-report-summary-mismatch"
    return failures, None


def _report_names(report_dir: Path) -> list[str]:
    return sorted(
        path.name
        for path in report_dir.glob("*.json")
        if path.is_file() and path.name != "failure-set.json"
    )


def _valid_expected_reports(values: Iterable[str]) -> list[str] | None:
    names = list(values)
    if not names or len(names) != len(set(names)):
        return None
    if any(Path(name).name != name or not name.endswith(".json") for name in names):
        return None
    return sorted(names)


def build_manifest(
    *,
    repo_root: Path,
    report_dir: Path,
    repository: str,
    workflow_run_id: str,
    workflow_run_attempt: int,
    event_name: str,
    event_path: Path,
    tested_commit: str,
    local_iteration_result: str,
    expected_reports: Iterable[str],
) -> dict[str, object]:
    del repo_root
    reasons: list[str] = []
    expected = _valid_expected_reports(expected_reports)
    if expected is None:
        reasons.append("report-inventory-invalid")
        expected = []
    observed = _report_names(report_dir)
    if expected != observed:
        reasons.append("report-inventory-mismatch")

    if not repository or "/" not in repository or any(char.isspace() for char in repository):
        reasons.append("repository-identity-invalid")
    if NUMERIC.fullmatch(str(workflow_run_id)) is None:
        reasons.append("workflow-run-id-invalid")
    if (
        not isinstance(workflow_run_attempt, int)
        or isinstance(workflow_run_attempt, bool)
        or workflow_run_attempt < 1
    ):
        reasons.append("workflow-run-attempt-invalid")
    if not _exact_oid(tested_commit):
        reasons.append("tested-commit-invalid")

    failures: list[dict[str, str]] = []
    seen: set[tuple[str, str, str]] = set()
    for name in observed:
        report_failures, report_reason = _read_report(report_dir / name)
        if report_reason is not None:
            reasons.append(report_reason)
            continue
        for failure in report_failures or []:
            identity = (failure["owner_namespace"], failure["file"], failure["name"])
            if identity not in seen:
                seen.add(identity)
                failures.append(failure)
    failures.sort(key=lambda item: (item["owner_namespace"], item["file"], item["name"]))

    result = _normalize_result(local_iteration_result)
    if result not in {"PASS:NONE", "FAIL:SEMANTIC"}:
        reasons.append("local-result-not-comparable")
    elif (result == "PASS:NONE" and failures) or (result == "FAIL:SEMANTIC" and not failures):
        reasons.append("local-result-report-mismatch")

    provenance = _event_provenance(event_name, event_path, reasons)
    manifest: dict[str, object] = {
        "schema": FAILURE_SET_SCHEMA,
        "repository": repository,
        "workflow_run_id": str(workflow_run_id),
        "workflow_run_attempt": workflow_run_attempt,
        "event_name": event_name,
        "tested_commit": tested_commit.lower() if _exact_oid(tested_commit) else tested_commit,
        "local_iteration_result": result,
        "complete": not reasons,
        "report_count": len(observed),
        "expected_report_count": len(expected),
        "failures": failures,
        **provenance,
    }
    if reasons:
        manifest["incomplete_reasons"] = sorted(set(reasons))
    return manifest


def _inventory(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--report-dir", type=Path, required=True)
    parser.add_argument("--inventory-file", type=Path, required=True)
    parser.add_argument("--result-file", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow-run-id", required=True)
    parser.add_argument("--workflow-run-attempt", type=int, required=True)
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--event-path", type=Path, required=True)
    parser.add_argument("--tested-commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        local_result = args.result_file.read_text(encoding="utf-8")
    except OSError:
        local_result = ""
    manifest = build_manifest(
        repo_root=args.repo_root,
        report_dir=args.report_dir,
        repository=args.repository,
        workflow_run_id=args.workflow_run_id,
        workflow_run_attempt=args.workflow_run_attempt,
        event_name=args.event_name,
        event_path=args.event_path,
        tested_commit=args.tested_commit,
        local_iteration_result=local_result,
        expected_reports=_inventory(args.inventory_file),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
