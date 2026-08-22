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

    def test_engine_compatibility_lane_provisions_both_historical_revisions(self) -> None:
        workflow = self.read_workflow()

        self.assertIn("id: liveness_engine_refs", workflow)
        self.assertIn("liveness_failure_domain_engine_refs.env", workflow)
        self.assertIn("ref: ${{ steps.liveness_engine_refs.outputs.pre_advance }}", workflow)
        self.assertIn("ref: ${{ steps.liveness_engine_refs.outputs.post_advance }}", workflow)
        self.assertIn("path: fkst-substrate-pre-advance", workflow)
        self.assertIn("path: fkst-substrate-post-advance", workflow)
        self.assertIn("Build historical fkst-framework compatibility binaries", workflow)
        self.assertIn("scripts/run.sh test-engine-compatibility", workflow)
        self.assertGreaterEqual(workflow.count('FKST_NO_AUTOBUILD: "1"'), 2)

    def test_engine_compatibility_refs_are_single_sourced(self) -> None:
        refs = (
            REPO_ROOT
            / "packages/github-devloop/tests/liveness_failure_domain_engine_refs.env"
        ).read_text(encoding="utf-8")
        values = {}
        for line in refs.splitlines():
            if not line or line.startswith("#"):
                continue
            name, value = line.split("=", 1)
            values[name] = value

        self.assertEqual(
            set(values),
            {"FKST_LIVENESS_PRE_ADVANCE_ENGINE_REF", "FKST_LIVENESS_POST_ADVANCE_ENGINE_REF"},
        )
        self.assertRegex(values["FKST_LIVENESS_PRE_ADVANCE_ENGINE_REF"], r"^[0-9a-f]{40}$")
        self.assertRegex(values["FKST_LIVENESS_POST_ADVANCE_ENGINE_REF"], r"^[0-9a-f]{40}$")
        self.assertNotEqual(
            values["FKST_LIVENESS_PRE_ADVANCE_ENGINE_REF"],
            values["FKST_LIVENESS_POST_ADVANCE_ENGINE_REF"],
        )
        for path in (
            REPO_ROOT / ".github/workflows/ci.yml",
            REPO_ROOT / "scripts/run.sh",
            REPO_ROOT / "scripts/test_engine_compatibility.sh",
            REPO_ROOT / "packages/github-devloop/tests/run_graph_liveness_failure_domain_test.lua",
        ):
            source = path.read_text(encoding="utf-8")
            for ref in values.values():
                self.assertNotIn(ref, source, f"duplicate compatibility ref in {path}")


if __name__ == "__main__":
    unittest.main()
