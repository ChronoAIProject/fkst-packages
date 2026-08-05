#!/usr/bin/env python3
"""Contract tests for the repository CI workflow."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _inline_branches_for_event(workflow: str, event: str) -> list[str]:
    in_on = False
    in_event = False
    for raw in workflow.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent == 0:
            in_on = stripped == "on:"
            in_event = False
            continue
        if not in_on:
            continue
        if indent == 2 and stripped.endswith(":"):
            in_event = stripped[:-1] == event
            continue
        if in_event and indent == 4:
            match = re.fullmatch(r"branches:\s*\[(.*)\]", stripped)
            if match:
                return [
                    item.strip().strip('"').strip("'")
                    for item in match.group(1).split(",")
                    if item.strip()
                ]
    raise AssertionError(f"could not find inline branches for workflow event {event!r}")


def _top_level_mapping(workflow: str, key: str) -> dict[str, str]:
    in_mapping = False
    values: dict[str, str] = {}
    for raw in workflow.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent == 0:
            if in_mapping:
                break
            in_mapping = stripped == f"{key}:"
            continue
        if in_mapping and indent == 2:
            name, sep, value = stripped.partition(":")
            if sep:
                values[name.strip()] = value.strip()
    if not values:
        raise AssertionError(f"could not find top-level mapping for workflow key {key!r}")
    return values


class CiWorkflowTest(unittest.TestCase):
    def read_workflow(self) -> str:
        return (REPO_ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")

    def test_pull_requests_targeting_fkst_hosted_run_package_checks(self) -> None:
        workflow = self.read_workflow()

        self.assertIn("fkst-hosted", _inline_branches_for_event(workflow, "pull_request"))
        self.assertIn("scripts/run.sh test", workflow)

    def test_pull_request_workflow_uses_least_privilege_token_permissions(self) -> None:
        workflow = self.read_workflow()

        self.assertEqual({"contents": "read"}, _top_level_mapping(workflow, "permissions"))

    def test_git_239_compatibility_gate_runs_the_executable_contract(self) -> None:
        workflow = self.read_workflow()
        compatibility_test = (REPO_ROOT / "scripts" / "git_compat_test.sh").read_text(encoding="utf-8")

        self.assertIn("git-239-compat:", workflow)
        self.assertIn("container: debian:bookworm-slim", workflow)
        self.assertIn("git version 2\\.39\\.", workflow)
        self.assertIn("scripts/git_compat_test.sh", workflow)
        self.assertIn("needs: git-239-compat", workflow)
        self.assertIn('require("forge.git")', compatibility_test)
        self.assertIn('.fetch_pr_head_oid("origin", 7, 60)', compatibility_test)
        self.assertNotIn("git fetch --", compatibility_test)

    def test_rollup_attestation_uses_one_entrypoint_after_trace_emission(self) -> None:
        workflow = self.read_workflow()

        tests_at = workflow.index("scripts/run.sh test")
        entrypoint_at = workflow.index("scripts/intent_diff_rollup_attestation.py")
        upload_at = workflow.index("name: intent-diff-rollup-attestation-", entrypoint_at)
        self.assertLess(tests_at, entrypoint_at)
        self.assertLess(entrypoint_at, upload_at)
        self.assertIn(
            "FKST_R9_TRACE_OUTPUT_DIR: ${{ github.workspace }}/.fkst/run/intent-diff-traces",
            workflow,
        )
        self.assertIn('--github-event "$GITHUB_EVENT_PATH"', workflow)
        self.assertNotIn("FKST_INTENT_DIFF_HEAD_REPOSITORY", workflow)
        self.assertNotIn("--carrier-pr-number", workflow)
        self.assertNotIn("--base-sha", workflow)
        self.assertNotIn("--head-sha", workflow)
        self.assertIn(".fkst/run/intent-diff-rollup-attestations/*.json", workflow)
        self.assertIn("if-no-files-found: ignore", workflow[upload_at:])


if __name__ == "__main__":
    unittest.main()
