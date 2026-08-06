#!/usr/bin/env python3
"""Build a complete, commit-bound set of producer-owned test failures."""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Iterable


SCHEMA = "fkst.test.failure-manifest.v1"
REPORT_SCHEMA = "fkst.test.report.v1"
SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")


def _normalized_sha(value: str | None) -> str | None:
    text = str(value or "")
    return text.lower() if SHA_RE.fullmatch(text) else None


def _count(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _load_report(path: Path) -> tuple[list[tuple[str, str, str]], int, str | None]:
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return [], 0, f"invalid-report:{path.name}:{type(exc).__name__}"
    if not isinstance(report, dict) or report.get("schema") != REPORT_SCHEMA:
        return [], 0, f"invalid-report-schema:{path.name}"
    summary = report.get("summary")
    tests = report.get("tests")
    if not isinstance(summary, dict) or not isinstance(tests, list):
        return [], 0, f"invalid-report-shape:{path.name}"
    expected_passed = _count(summary.get("passed"))
    expected_failed = _count(summary.get("failed"))
    if expected_passed is None or expected_failed is None:
        return [], 0, f"invalid-report-summary:{path.name}"

    failures: list[tuple[str, str, str]] = []
    passed = 0
    failed = 0
    for entry in tests:
        if not isinstance(entry, dict) or entry.get("status") not in {"pass", "fail"}:
            return [], 0, f"invalid-test-entry:{path.name}"
        identity = tuple(entry.get(field) for field in ("owner_namespace", "file", "name"))
        if any(not isinstance(field, str) or not field for field in identity):
            return [], 0, f"invalid-test-identity:{path.name}"
        if entry["status"] == "fail":
            failed += 1
            failures.append(identity)  # type: ignore[arg-type]
        else:
            passed += 1
    if passed != expected_passed or failed != expected_failed:
        return [], 0, f"report-summary-mismatch:{path.name}"
    return failures, failed, None


def build_manifest(
    *,
    report_dir: Path,
    expected_reports: Iterable[tuple[str, str]],
    completed_units: set[str],
    observed_failure_units: int,
    tested_commit: str,
    base_commit: str | None,
    head_commit: str | None,
    event_name: str,
) -> dict[str, object]:
    reasons: list[str] = []
    normalized_tested = _normalized_sha(tested_commit)
    normalized_base = _normalized_sha(base_commit)
    normalized_head = _normalized_sha(head_commit)
    if normalized_tested is None:
        reasons.append("invalid-tested-commit")
    if event_name == "pull_request":
        if normalized_base is None:
            reasons.append("invalid-base-commit")
        if normalized_head is None:
            reasons.append("invalid-head-commit")

    expected = list(expected_reports)
    expected_names: set[str] = set()
    expected_units: set[str] = set()
    failures: set[tuple[str, str, str]] = set()
    failed_units: set[str] = set()
    report_count = 0
    for unit, file_name in expected:
        expected_units.add(unit)
        if not unit or not file_name or Path(file_name).name != file_name:
            reasons.append("invalid-expected-report")
            continue
        if file_name in expected_names:
            reasons.append(f"duplicate-expected-report:{file_name}")
            continue
        expected_names.add(file_name)
        path = report_dir / file_name
        if not path.is_file():
            reasons.append(f"missing-report:{file_name}")
            continue
        report_failures, failed_count, error = _load_report(path)
        if error is not None:
            reasons.append(error)
            continue
        report_count += 1
        failures.update(report_failures)
        if failed_count > 0:
            failed_units.add(unit)

    for unit in sorted(expected_units - completed_units):
        reasons.append(f"incomplete-unit:{unit}")
    unexpected = {
        path.name
        for path in report_dir.glob("*.json")
        if path.name != "failure-manifest.json" and path.name not in expected_names
    }
    reasons.extend(f"unexpected-report:{name}" for name in sorted(unexpected))
    if observed_failure_units != len(failed_units):
        reasons.append("failure-unit-count-mismatch")

    manifest: dict[str, object] = {
        "schema": SCHEMA,
        "event_name": str(event_name or ""),
        "tested_commit": normalized_tested or "",
        "complete": not reasons,
        "report_count": report_count,
        "failures": [
            {"owner_namespace": owner, "file": file_name, "name": name}
            for owner, file_name, name in sorted(failures)
        ],
    }
    if normalized_base is not None:
        manifest["base_commit"] = normalized_base
    if normalized_head is not None:
        manifest["head_commit"] = normalized_head
    if reasons:
        manifest["incomplete_reasons"] = sorted(set(reasons))
    return manifest


def _expected_report(value: str) -> tuple[str, str]:
    unit, separator, file_name = value.partition("=")
    if not separator or not unit or not file_name:
        raise argparse.ArgumentTypeError("expected report must be UNIT=FILE")
    return unit, file_name


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-report", action="append", default=[], type=_expected_report)
    parser.add_argument("--completed-unit", action="append", default=[])
    parser.add_argument("--observed-failure-units", required=True, type=int)
    parser.add_argument("--tested-commit", required=True)
    parser.add_argument("--base-commit", default="")
    parser.add_argument("--head-commit", default="")
    parser.add_argument("--event-name", default="")
    args = parser.parse_args()

    manifest = build_manifest(
        report_dir=args.report_dir,
        expected_reports=args.expected_report,
        completed_units=set(args.completed_unit),
        observed_failure_units=args.observed_failure_units,
        tested_commit=args.tested_commit,
        base_commit=args.base_commit,
        head_commit=args.head_commit,
        event_name=args.event_name,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(f".{args.output.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
