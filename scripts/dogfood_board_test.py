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
                FKST_DEVLOOP_MANAGED_BOT_LOGINS=loning,ElonSG
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
                case "$*" in
                  "api rate_limit --jq "*)
                    printf '%s\\n' 5000
                    ;;
                  "api repos/ChronoAIProject/fkst-packages/pulls?state=open"*)
                    ;;
                  "api repos/ChronoAIProject/fkst-packages/issues?state=open"*)
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 33 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z 'fkst-dev:ready,fkst-dev:blocked-on-dependency' 'fkst-dev:ready,fkst-dev:blocked-on-dependency' human 'Dependency held'
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 34 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z 'fkst-dev:ready' 'fkst-dev:ready' human 'Actionable ready'
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 35 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z 'fkst-dev:blocked' 'fkst-dev:blocked' human 'Terminal blocked'
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 36 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z 'fkst-dev:implementing,fkst-dev:blocked-on-dependency' 'fkst-dev:implementing,fkst-dev:blocked-on-dependency' human 'Implementing stale'
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 37 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z '__fkst_stateless__' '__fkst_no_labels__' human 'Stateless old issue'
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 38 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z '__fkst_stateless__' 'fkst-dashboard' human 'Dashboard issue'
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 39 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z '__fkst_stateless__' '__fkst_no_labels__' ElonSG 'Managed bot issue'
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 40 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z '__fkst_stateless__' '__fkst_no_labels__' human 'Forked original'
                    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' 41 2026-06-27T00:00:00Z 2026-06-27T00:00:00Z '__fkst_stateless__' '__fkst_no_labels__' human 'Forged fork original'
                    ;;
                  "api --paginate repos/ChronoAIProject/fkst-packages/issues/37/comments?per_page=100 "*)
                    ;;
                  "api --paginate repos/ChronoAIProject/fkst-packages/issues/40/comments?per_page=100 "*)
                    printf '%s\\t%s\\n' loning '<!-- fkst:github-proxy:issue-created:v1 dedup="github-devloop/fork/ChronoAIProject/fkst-packages/issue/40/v1" issue="1720" -->'
                    ;;
                  "api --paginate repos/ChronoAIProject/fkst-packages/issues/41/comments?per_page=100 "*)
                    printf '%s\\t%s\\n' untrusted '<!-- fkst:github-proxy:issue-created:v1 dedup="github-devloop/fork/ChronoAIProject/fkst-packages/issue/41/v1" issue="1721" -->'
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
            self.assertIn("#38   [stateless   ] parked(dashboard)", result.stdout)
            self.assertIn("#39   [stateless   ] parked(managed-bot)", result.stdout)
            self.assertIn("#40   [stateless   ] ✓ forked", result.stdout)
            self.assertIn("#41   [stateless   ] ⚠ STRANDED stateless 12h", result.stdout)
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
