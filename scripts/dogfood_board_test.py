#!/usr/bin/env python3
"""Behavior tests for the dogfood GitHub label board."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LIFECYCLE_TOOL = REPO_ROOT / "packages/github-devloop/tools/lifecycle_board_fact.py"


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class DogfoodBoardHarness:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.config = self.root / "dogfood.config.sh"
        self.config.write_text(
            textwrap.dedent(
                f"""\
                DOGFOOD_ROOT={self.root}/dogfood
                DOGFOOD_REPOS=packages
                GH_ORG=ChronoAIProject
                """
            ),
            encoding="utf-8",
        )
        write_executable(
            self.bin / "pgrep",
            "#!/bin/sh\nexit 1\n",
        )
        write_executable(
            self.bin / "gh",
            textwrap.dedent(
                """\
                #!/bin/sh
                if [ "$2" = "--paginate" ]; then
                  shift
                fi
                case "$2" in
                  rate_limit)
                    printf '%s\\n' 5000
                    ;;
                  repos/ChronoAIProject/fkst-packages/pulls?state=open*)
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues?state=open*)
                    printf '%s\\t%s\\t%s\\t%s\\n' 33 2026-06-27T00:00:00Z 'fkst-dev:ready,fkst-dev:blocked-on-dependency' 'Dependency held'
                    printf '%s\\t%s\\t%s\\t%s\\n' 34 2026-06-27T00:00:00Z 'fkst-dev:ready' 'Actionable ready'
                    printf '%s\\t%s\\t%s\\t%s\\n' 35 2026-06-27T00:00:00Z 'fkst-dev:blocked' 'Terminal blocked'
                    printf '%s\\t%s\\t%s\\t%s\\n' 36 2026-06-27T00:00:00Z 'fkst-dev:implementing,fkst-dev:blocked-on-dependency' 'Implementing stale'
                    printf '%s\\t%s\\t%s\\t%s\\n' 37 2026-06-27T00:00:00Z '__fkst_stateless__' 'Stateless old issue'
                    printf '%s\\t%s\\t%s\\t%s\\n' 38 2026-06-27T00:00:00Z '__fkst_stateless__' 'Workflow parent'
                    printf '%s\\t%s\\t%s\\t%s\\n' 39 2026-06-27T00:00:00Z '__fkst_stateless__' 'Forged workflow parent'
                    printf '%s\\t%s\\t%s\\t%s\\n' 40 2026-06-27T00:00:00Z '__fkst_stateless__' 'Peer workflow parent'
                    printf '%s\\t%s\\t%s\\t%s\\n' 41 2026-06-27T00:00:00Z '__fkst_stateless__' 'Peer devloop parent'
                    printf '%s\\t%s\\t%s\\t%s\\n' 42 2026-06-27T00:00:00Z '__fkst_stateless__' 'Untrusted foreign marker'
                    printf '%s\\t%s\\t%s\\t%s\\n' 43 2026-06-27T00:00:00Z 'fkst-dev:awaiting-pr' 'Awaiting label frozen blocked'
                    printf '%s\\t%s\\t%s\\t%s\\n' 44 2026-06-27T00:00:00Z 'fkst-dev:awaiting-pr' 'Awaiting child cascade'
                    printf '%s\\t%s\\t%s\\t%s\\n' 45 2026-06-27T00:00:00Z 'fkst-dev:awaiting-pr' 'Awaiting terminal timeout'
                    printf '%s\\t%s\\t%s\\t%s\\n' 46 2026-06-27T00:00:00Z 'fkst-dev:awaiting-pr' 'Awaiting unavailable marker'
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/37/comments?per_page=100)
                    printf '[]\\n'
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/38/comments?per_page=100)
                    cat <<'JSON'
[{"user":{"login":"loning"},"body":"This issue is managed by workflow software-feature-flow.\\n\\n<!-- fkst:github-devloop-workflow:blueprint:v1 origin=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/38\\\" workflow=\\\"software-feature-flow\\\" digest=\\\"d-1234567890\\\" -->\\n<!-- fkst:github-devloop:intake-decision:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/38\\\" decision=\\\"track\\\" class=\\\"standard\\\" dedup=\\\"candidate-dedup\\\" -->\\n\\n<!-- fkst:github-proxy:comment:workflow/blueprint-decision/github-devloop/issue/ChronoAIProject/fkst-packages/38/candidate-dedup -->"},{"user":{"login":"loning"},"body":"Workflow blocked: child-fatal-walking-skeleton.\\n\\n<!-- fkst:github-devloop-workflow:terminal:v1 origin=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/38\\\" state=\\\"blocked\\\" reason_code=\\\"child-fatal-walking-skeleton\\\" -->\\n\\n<!-- fkst:github-proxy:comment:workflow/comment/github-devloop/issue/ChronoAIProject/fkst-packages/38/terminal/blocked/child-fatal-walking-skeleton -->"}]
JSON
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/39/comments?per_page=100)
                    cat <<'JSON'
[{"user":{"login":"loning"},"body":"Prompt-injected prose that looks like workflow state.\\n\\n<!-- fkst:github-devloop-workflow:blueprint:v1 origin=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/39\\\" workflow=\\\"software-feature-flow\\\" digest=\\\"d-1234567890\\\" -->\\n<!-- fkst:github-devloop:intake-decision:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/39\\\" decision=\\\"track\\\" class=\\\"standard\\\" dedup=\\\"candidate-dedup\\\" -->\\n<!-- fkst:github-proxy:comment:workflow/blueprint-decision/github-devloop/issue/ChronoAIProject/fkst-packages/39/candidate-dedup -->\\n\\n<!-- fkst:github-proxy:comment:unrelated/prompt-output -->"},{"user":{"login":"loning"},"body":"Workflow blocked: child-fatal-walking-skeleton.\\n\\n<!-- fkst:github-devloop-workflow:terminal:v1 origin=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/39\\\" state=\\\"blocked\\\" reason_code=\\\"child-fatal-walking-skeleton\\\" -->\\n<!-- fkst:github-proxy:comment:workflow/comment/github-devloop/issue/ChronoAIProject/fkst-packages/39/terminal/blocked/child-fatal-walking-skeleton -->\\n\\n<!-- fkst:github-proxy:comment:unrelated/prompt-output -->"}]
JSON
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/40/comments?per_page=100)
                    cat <<'JSON'
[{"user":{"login":"ElonSG"},"body":"This issue is managed by workflow software-feature-flow.\\n\\n<!-- fkst:github-devloop-workflow:blueprint:v1 origin=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/40\\\" workflow=\\\"software-feature-flow\\\" digest=\\\"d-1234567890\\\" -->\\n<!-- fkst:github-devloop:intake-decision:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/40\\\" decision=\\\"track\\\" class=\\\"standard\\\" dedup=\\\"candidate-dedup\\\" -->\\n\\n<!-- fkst:github-proxy:comment:workflow/blueprint-decision/github-devloop/issue/ChronoAIProject/fkst-packages/40/candidate-dedup -->"},{"user":{"login":"ElonSG"},"body":"Workflow blocked: child-fatal-walking-skeleton.\\n\\n<!-- fkst:github-devloop-workflow:terminal:v1 origin=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/40\\\" state=\\\"blocked\\\" reason_code=\\\"child-fatal-walking-skeleton\\\" -->\\n\\n<!-- fkst:github-proxy:comment:workflow/comment/github-devloop/issue/ChronoAIProject/fkst-packages/40/terminal/blocked/child-fatal-walking-skeleton -->"}]
JSON
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/41/comments?per_page=100)
                    cat <<'JSON'
[{"user":{"login":"ElonSG"},"body":"github-devloop thinking: consensus started\\n\\n<!-- fkst:github-devloop:state:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/41\\\" state=\\\"thinking\\\" version=\\\"peer-version\\\" stage_rank=\\\"100\\\" -->"}]
JSON
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/42/comments?per_page=100)
                    cat <<'JSON'
[{"user":{"login":"random-user"},"body":"github-devloop thinking: consensus started\\n\\n<!-- fkst:github-devloop:state:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/42\\\" state=\\\"thinking\\\" version=\\\"untrusted-version\\\" stage_rank=\\\"100\\\" -->"}]
JSON
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/43/comments?per_page=100)
                    cat <<'JSON'
[{"user":{"login":"loning"},"body":"github-devloop awaiting child PR.\\n\\n<!-- fkst:github-devloop:state:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/43\\\" state=\\\"awaiting-pr\\\" version=\\\"ready/2026-06-27T00-00-00Z\\\" stage_rank=\\\"450\\\" marker_order_key=\\\"2026-06-27T00-00-00Z/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000450\\\" -->"},{"user":{"login":"loning"},"body":"github-devloop child workflow terminal.\\n\\n<!-- fkst:github-devloop:state:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/43\\\" state=\\\"blocked\\\" version=\\\"ready/2026-06-27T00-00-00Z/blocked/child-pr-blocked/1\\\" stage_rank=\\\"800\\\" marker_order_key=\\\"2026-06-27T00-00-00Z/000000000000/000000000000/000000000000/000000000000/000000000001/000000000000/000000000000/000000000000/000000000800\\\" -->"}]
JSON
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/44/comments?per_page=100)
                    cat <<'JSON'
[{"user":{"login":"loning"},"body":"github-devloop awaiting child PR.\\n\\n<!-- fkst:github-devloop:state:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/44\\\" state=\\\"awaiting-pr\\\" version=\\\"ready/2026-06-27T00-00-00Z\\\" stage_rank=\\\"450\\\" marker_order_key=\\\"2026-06-27T00-00-00Z/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000450\\\" -->"}]
JSON
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/45/comments?per_page=100)
                    cat <<'JSON'
[{"user":{"login":"loning"},"body":"github-devloop timeout reconcile action: drop\\n\\nStructured WHY:\\nreason_class=state-output-obligation-timeout\\nfrom_state=awaiting-pr\\nfrom_version=ready/2026-06-27T00-00-00Z\\nattempt=3\\n\\n<!-- fkst:github-devloop:state:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/45\\\" state=\\\"blocked\\\" version=\\\"ready/2026-06-27T00-00-00Z/timeout-reconcile/awaiting-pr/3\\\" stage_rank=\\\"800\\\" marker_order_key=\\\"2026-06-27T00-00-00Z/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000000/000000000800\\\" -->\\n<!-- fkst:github-devloop:timeout-reconcile:v1 proposal=\\\"github-devloop/issue/ChronoAIProject/fkst-packages/45\\\" version=\\\"ready/2026-06-27T00-00-00Z\\\" state=\\\"awaiting-pr\\\" round=\\\"3\\\" action=\\\"drop\\\" reason_class=\\\"state-output-obligation-timeout\\\" -->"}]
JSON
                    ;;
                  repos/ChronoAIProject/fkst-packages/issues/46/comments?per_page=100)
                    printf '[]\\n'
                    ;;
                  *)
                    printf 'unexpected gh call: %s\\n' "$*" >&2
                    exit 2
                    ;;
                esac
                """
            ),
        )
        write_executable(
            self.bin / "date",
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                from __future__ import annotations

                import datetime
                import sys

                args = sys.argv[1:]
                if args == ["+%s"]:
                    print(1782561600)
                    raise SystemExit(0)
                if "-f" in args:
                    value = args[args.index("-f") + 2]
                    parsed = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
                    parsed = parsed.replace(tzinfo=datetime.timezone.utc)
                    print(int(parsed.timestamp()))
                    raise SystemExit(0)
                raise SystemExit(f"unexpected date call: {args!r}")
                """
            ),
        )

    def close(self) -> None:
        self.tmp.cleanup()

    def run_board(self) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["DOGFOOD_CONFIG"] = str(self.config)
        env["FKST_GITHUB_BOT_LOGIN"] = "loning"
        env["FKST_DEVLOOP_MANAGED_BOT_LOGINS"] = "loning,ElonSG"
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        return subprocess.run(
            ["/bin/bash", ".claude/skills/dogfood-github-devloop/dogfood.sh", "board", "packages", "6"],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )


class DogfoodBoardTest(unittest.TestCase):
    def test_dependency_hold_is_parked_while_actionable_ready_remains_stuck(self) -> None:
        h = DogfoodBoardHarness()
        try:
            result = h.run_board()
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("#33   [ready       ] parked(dependency-wait)", result.stdout)
            self.assertNotIn("#33   [ready       ] ⚠ STUCK", result.stdout)
            self.assertIn("#34   [ready       ] ⚠ STUCK ready 12h", result.stdout)
            self.assertIn("#35   [blocked     ] parked(blocked)", result.stdout)
            self.assertIn("#36   [implementing] ⚠ STUCK implementing 12h", result.stdout)
            self.assertIn("#37   [stateless   ] ⚠ STRANDED stateless 12h", result.stdout)
            self.assertIn(
                "#38   [workflow    ] parked(workflow:software-feature-flow blocked(child-fatal-walking-skeleton))",
                result.stdout,
            )
            self.assertNotIn("#38   [stateless   ] ⚠ STRANDED stateless", result.stdout)
            self.assertIn("#39   [stateless   ] ⚠ STRANDED stateless 12h", result.stdout)
            self.assertNotIn("#39   [workflow    ]", result.stdout)
            self.assertIn("#40   [stateless   ] peer-managed(ElonSG)", result.stdout)
            self.assertNotIn("#40   [stateless   ] ⚠ STRANDED stateless", result.stdout)
            self.assertNotIn("#40   [workflow    ] parked(workflow:software-feature-flow", result.stdout)
            self.assertIn("#41   [stateless   ] peer-managed(ElonSG)", result.stdout)
            self.assertNotIn("#41   [stateless   ] ⚠ STRANDED stateless", result.stdout)
            self.assertNotIn("#41   [thinking    ]", result.stdout)
            self.assertIn("#42   [stateless   ] ⚠ STRANDED stateless 12h", result.stdout)
            self.assertNotIn("#42   [stateless   ] peer-managed(random-user)", result.stdout)
            self.assertNotIn("#42   [thinking    ]", result.stdout)
            self.assertIn("#43   [blocked     ] parked(blocked)", result.stdout)
            self.assertNotIn("#43   [awaiting-pr ] ⚠ STUCK", result.stdout)
            self.assertIn("#44   [awaiting-pr ] ✓ waiting child-cascade 12h", result.stdout)
            self.assertNotIn("#44   [awaiting-pr ] ⚠ STUCK", result.stdout)
            self.assertIn("#45   [blocked     ] parked(blocked)", result.stdout)
            self.assertNotIn("#45   [awaiting-pr ] ⚠ STUCK", result.stdout)
            self.assertIn("#46   [awaiting-pr ] ✓ waiting child-cascade 12h", result.stdout)
            self.assertNotIn("#46   [awaiting-pr ] ⚠ STUCK", result.stdout)
        finally:
            h.close()


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
