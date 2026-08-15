#!/usr/bin/env python3
"""Behavior tests for the package-owned lifecycle board fact CLI."""

from __future__ import annotations

import json
import subprocess
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LIFECYCLE_TOOL = REPO_ROOT / "packages/github-devloop/tools/lifecycle_board_fact.py"


class LifecycleBoardFactTest(unittest.TestCase):
    def run_tool(self, comments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                "-B",
                str(LIFECYCLE_TOOL),
                "--origin",
                "github-devloop/issue/ChronoAIProject/fkst-packages/43",
                "--bot-login",
                "loning",
                "--managed-bot-logins",
                "loning,ElonSG",
            ],
            input=comments,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_pr_tool(self, comments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                "-B",
                str(LIFECYCLE_TOOL),
                "--discover-pr-origin",
                "--bot-login",
                "loning",
                "--managed-bot-logins",
                "loning,ElonSG",
            ],
            input=comments,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_pr_projection_distinguishes_unmanaged_from_unavailable(self) -> None:
        unmanaged = self.run_pr_tool("[]")
        self.assertEqual(unmanaged.returncode, 1, unmanaged.stderr + unmanaged.stdout)

        unavailable = self.run_pr_tool(
            json.dumps(
                [
                    {
                        "user": {"login": "loning"},
                        "body": (
                            '<!-- fkst:github-devloop:pr-origin:v1 '
                            'proposal="github-devloop/issue/ChronoAIProject/fkst-packages/43" '
                            'issue="43" branch="feature" impl_version="ready/43" '
                            'base_branch="integration" -->'
                        ),
                    }
                ]
            )
        )
        self.assertEqual(unavailable.returncode, 2, unavailable.stderr + unavailable.stdout)

    def test_pr_projection_ignores_noncanonical_marker_whitespace(self) -> None:
        comments = json.dumps(
            [
                {
                    "user": {"login": "loning"},
                    "created_at": "2026-06-27T00:00:00Z",
                    "body": (
                        '<!-- fkst:github-devloop:pr-origin:v1 '
                        'proposal="github-devloop/issue/ChronoAIProject/fkst-packages/43" -->\n'
                        '<!-- fkst:github-devloop:state:v1 '
                        'proposal="github-devloop/issue/ChronoAIProject/fkst-packages/43" '
                        'state="fixing" version="2026-06-27T00-00-00Z/fixing" '
                        'marker_order_key="2026-06-27T00-00-00Z/0000000200" -->'
                    ),
                },
                {
                    "user": {"login": "loning"},
                    "created_at": "2099-01-01T00:00:00Z",
                    "body": (
                        '<!--  fkst:github-devloop:state:v1 '
                        'proposal="github-devloop/issue/ChronoAIProject/fkst-packages/43" '
                        'state="fixing" version="2099-01-01T00-00-00Z/fixing" '
                        'marker_order_key="2099-01-01T00-00-00Z/0000000200" -->'
                    ),
                },
            ]
        )
        result = self.run_pr_tool(comments)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)["condition_started_at"], "2026-06-27T00:00:00Z")

    def test_lifecycle_projector_uses_trusted_marker_order_key(self) -> None:
        comments = textwrap.dedent(
            """\
            [{"user":{"login":"random-user"},"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"github-devloop/issue/ChronoAIProject/fkst-packages/43\\" state=\\"merged\\" version=\\"z\\" stage_rank=\\"900\\" marker_order_key=\\"z/0000000900\\" -->"},
             {"user":{"login":"loning"},"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"github-devloop/issue/ChronoAIProject/fkst-packages/43\\" state=\\"awaiting-pr\\" version=\\"ready/1\\" stage_rank=\\"450\\" marker_order_key=\\"ready/1/0000000450\\" -->"},
             {"user":{"login":"loning"},"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"github-devloop/issue/ChronoAIProject/fkst-packages/43\\" state=\\"blocked\\" version=\\"ready/1/blocked/child\\" stage_rank=\\"800\\" marker_order_key=\\"ready/1/blocked/child/0000000800\\" -->"}]
            """
        )
        result = self.run_tool(comments)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), '{"state":"blocked","terminal":true}')

    def test_lifecycle_projector_preserves_current_marker_condition_onset(self) -> None:
        comments = json.dumps(
            [
                {
                    "user": {"login": "loning"},
                    "created_at": "2026-06-03T02:00:00Z",
                    "body": (
                        '<!-- fkst:github-devloop:state:v1 '
                        'proposal="github-devloop/issue/ChronoAIProject/fkst-packages/43" '
                        'state="ready" version="ready/1" stage_rank="500" '
                        'marker_order_key="ready/1/0000000500" -->'
                    ),
                }
            ]
        )
        result = self.run_tool(comments)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "state": "ready",
                "terminal": False,
                "condition_started_at": "2026-06-03T02:00:00Z",
            },
        )

    def test_lifecycle_projector_fails_closed_without_order_key(self) -> None:
        comments = textwrap.dedent(
            """\
            [{"user":{"login":"loning"},"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"github-devloop/issue/ChronoAIProject/fkst-packages/43\\" state=\\"blocked\\" version=\\"ready/1\\" stage_rank=\\"800\\" -->"}]
            """
        )
        result = self.run_tool(comments)
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertEqual(result.stdout, "")

    def test_lifecycle_projector_prefers_timestamped_primary_over_timestampless_fallback(self) -> None:
        comments = textwrap.dedent(
            """\
            [{"user":{"login":"loning"},"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"github-devloop/issue/ChronoAIProject/fkst-packages/43\\" state=\\"ready\\" version=\\"2026-06-04T01-02-03Z/ready\\" stage_rank=\\"300\\" marker_order_key=\\"2026-06-04T01-02-03Z/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000300\\" -->"},
             {"user":{"login":"loning"},"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"github-devloop/issue/ChronoAIProject/fkst-packages/43\\" state=\\"blocked\\" version=\\"github-devloop-issue-owner-re-003332718963/blocked\\" stage_rank=\\"800\\" marker_order_key=\\"github-devloop-issue-owner-re-001972576632/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000800\\" -->"}]
            """
        )
        result = self.run_tool(comments)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout.strip(), '{"state":"ready","terminal":false}')


if __name__ == "__main__":
    unittest.main()
