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

    def test_intent_diff_attestation_uses_actual_pr_context_after_tests(self) -> None:
        workflow = self.read_workflow()

        test_job_at = workflow.index("\n  test:\n")
        checkout_at = workflow.index("- name: Checkout fkst-packages", test_job_at)
        head_ref_at = workflow.index(
            "ref: ${{ github.event.pull_request.head.sha || github.sha }}",
            checkout_at,
        )
        tests_at = workflow.index("scripts/run.sh test")
        attestation_at = workflow.index("scripts/generate_intent_diff_attestation.py")
        self.assertLess(head_ref_at, tests_at)
        self.assertLess(tests_at, attestation_at)
        self.assertIn("github.event.pull_request.number", workflow)
        self.assertIn("github.event.pull_request.head.sha", workflow)
        self.assertIn("origin/${{ github.base_ref }}", workflow)
        self.assertIn(
            "FKST_R9_TRACE_OUTPUT_DIR: ${{ github.workspace }}/.fkst/run/intent-diff-traces",
            workflow,
        )
        self.assertIn("--trace-root .fkst/run/intent-diff-traces", workflow)
        self.assertIn(".fkst/run/intent-diff-attestations", workflow)
        self.assertIn("actions/upload-artifact@v4", workflow[attestation_at:])

    def test_pull_request_merge_result_is_tested_separately(self) -> None:
        workflow = self.read_workflow()

        merge_checkout = """      - name: Checkout pull request merge result
        if: github.event_name == 'pull_request'
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          path: pull-request-merge
"""
        merge_ref = """      - name: Resolve pull request merge fkst-substrate source pin
        if: github.event_name == 'pull_request'
        id: merge_substrate_ref
        working-directory: pull-request-merge
"""
        merge_engine_checkout = """      - name: Checkout pull request merge fkst-substrate
        if: github.event_name == 'pull_request'
        uses: actions/checkout@v4
        with:
          repository: ChronoAIProject/fkst-substrate
          ref: ${{ steps.merge_substrate_ref.outputs.ref }}
          path: pull-request-merge-fkst-substrate
"""
        merge_build = """      - name: Build pull request merge fkst-framework
        if: github.event_name == 'pull_request'
        working-directory: pull-request-merge-fkst-substrate
        run: cargo build -p fkst-framework
"""
        merge_test = """      - name: Test pull request merge result
        if: github.event_name == 'pull_request'
        working-directory: pull-request-merge
        env:
          BIN: ${{ github.workspace }}/pull-request-merge-fkst-substrate/target/debug/fkst-framework
        run: |
          test -x "$BIN"
          scripts/run.sh test
"""
        checkout_at = workflow.index(merge_checkout)
        merge_ref_at = workflow.index(merge_ref)
        merge_engine_checkout_at = workflow.index(merge_engine_checkout)
        merge_build_at = workflow.index(merge_build)
        test_at = workflow.index(merge_test)
        self.assertLess(checkout_at, merge_ref_at)
        self.assertLess(merge_ref_at, merge_engine_checkout_at)
        self.assertLess(merge_engine_checkout_at, merge_build_at)
        self.assertLess(merge_build_at, test_at)


if __name__ == "__main__":
    unittest.main()
