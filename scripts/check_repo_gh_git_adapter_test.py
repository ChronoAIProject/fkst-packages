#!/usr/bin/env python3
"""Unit tests for the gh/git adapter repository ratchet."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from check_repo_test import load_check_repo


check_repo = load_check_repo()


class GhGitAdapterRatchetTest(unittest.TestCase):
    def messages(self, sources: dict[str, str], allowlist: dict[str, set[str]] | None = None) -> list[str]:
        return check_repo.gh_git_adapter.ratchet_messages(sources, allowlist or {})

    def test_builder_literal_is_flagged(self) -> None:
        messages = self.messages({
            "packages/example/core.lua": 'return "gh issue list"\n',
        })

        self.assertEqual(len(messages), 1)
        self.assertIn("packages/example/core.lua constructs a new gh/git command head 'gh issue'", messages[0])

    def test_log_message_literal_is_excluded(self) -> None:
        messages = self.messages({
            "packages/example/core.lua": 'log.info("git merge done")\n',
        })

        self.assertEqual(messages, [])

    def test_exec_wrapper_context_labels_are_excluded(self) -> None:
        source = (
            "run_cmd(core.git_fetch_branch_cmd('origin', b), 60, 'git rollup fetch')\n"
            "gh_exec(M.gh_issue_blocked_by_cmd(r,n), 30, 'gh blockedBy view')\n"
        )

        self.assertEqual(check_repo.gh_git_adapter.command_heads(source), set())

    def test_literal_commands_remain_flagged(self) -> None:
        source = (
            "function M.gh_issue_list_cmd(r)\n"
            "  return 'gh issue list --repo ' .. r\n"
            "end\n"
            "local cmd = 'git push origin ' .. ref\n"
            "gh_exec('gh api graphql', 30, 'gh label context')\n"
        )

        self.assertEqual(check_repo.gh_git_adapter.command_heads(source), {"gh issue", "git push", "gh api"})

    def test_dotted_receiver_and_multiline_wrapper_calls(self) -> None:
        # Stable synthetic fixture (no real-file dependency) pinning the parser across
        # dotted-receiver wrappers (M./core. prefixes) and multiline call syntax: a label
        # argument is excluded, while an arg-0 inline command stays flagged in both shapes.
        source = (
            "core.gh_exec(M.gh_issue_blocked_by_cmd(r, n), 30, 'gh blockedBy view')\n"
            "M.gh_exec('gh pr merge --admin', 30, 'merge context')\n"
            "run_git(\n"
            "  core.git_push_cmd(worktree, branch),\n"
            "  120,\n"
            "  'git resolved branch sync push'\n"
            ")\n"
            "run_cmd(\n"
            "  'git fetch origin ' .. branch,\n"
            "  60,\n"
            "  'git fetch context'\n"
            ")\n"
        )

        self.assertEqual(check_repo.gh_git_adapter.command_heads(source), {"gh pr", "git fetch"})

    def test_cited_context_label_files_no_longer_report_label_only_heads(self) -> None:
        root = Path(__file__).resolve().parents[1]
        sources = {
            rel: (root / rel).read_text(encoding="utf-8")
            for rel in (
                "packages/github-devloop-integration/departments/rollup_scan/main.lua",
                "packages/github-proxy/core/blocked_by.lua",
                "packages/github-devloop-ops/core/ensure_repo.lua",
                "packages/fkst-substrate-ref-maintainer/core/substrate_ref.lua",
            )
        }
        heads_by_file = check_repo.gh_git_adapter.command_heads_by_file(sources)

        self.assertNotIn("git rollup", heads_by_file.get("packages/github-devloop-integration/departments/rollup_scan/main.lua", set()))
        self.assertNotIn("gh rollup", heads_by_file.get("packages/github-devloop-integration/departments/rollup_scan/main.lua", set()))
        self.assertNotIn("gh blockedBy", heads_by_file.get("packages/github-proxy/core/blocked_by.lua", set()))
        self.assertNotIn("git integration", heads_by_file.get("packages/github-devloop-ops/core/ensure_repo.lua", set()))
        self.assertNotIn("gh substrate-ref", heads_by_file.get("packages/fkst-substrate-ref-maintainer/core/substrate_ref.lua", set()))
        self.assertNotIn("git substrate-ref", heads_by_file.get("packages/fkst-substrate-ref-maintainer/core/substrate_ref.lua", set()))
        self.assertNotIn("git stale", heads_by_file.get("packages/fkst-substrate-ref-maintainer/core/substrate_ref.lua", set()))

    def test_env_cd_absolute_path_shell_c_and_concat_are_normalized(self) -> None:
        source = (
            'local a = "FOO=1 cd /tmp && /usr/local/bin/git" .. " -C /repo status --short"\n'
            'local b = "bash -c \\"gh pr view\\""\n'
            'local c = "GH_HOST=github.com gh" .. " issue view 1"\n'
        )
        heads = check_repo.gh_git_adapter.command_heads(source)

        self.assertEqual(heads, {"git status", "gh pr", "gh issue"})

    def test_new_head_in_allowlisted_file_fails(self) -> None:
        messages = self.messages(
            {"packages/example/core.lua": 'return "gh issue list"\nreturn "git status"\n'},
            {"packages/example/core.lua": {"gh issue"}},
        )

        self.assertEqual(len(messages), 1)
        self.assertIn("constructs a new gh/git command head 'git status'", messages[0])

    def test_stale_head_forces_allowlist_shrink(self) -> None:
        messages = self.messages(
            {"packages/example/core.lua": 'return "gh issue list"\n'},
            {"packages/example/core.lua": {"gh issue", "git status"}},
        )

        self.assertEqual(len(messages), 1)
        self.assertIn("no longer constructs 'git status'; update its entry", messages[0])

    def test_root_std_non_adapter_flagged_and_std_github_exempt(self) -> None:
        sources = {
            "libraries/forge/helpers.lua": 'return "git status"\n',
            "libraries/forge/github/exec.lua": 'return "gh issue list"\n',
            "libraries/forge/github.lua": 'return "gh pr view"\n',
        }

        messages = self.messages(sources)

        self.assertEqual(len(messages), 1)
        self.assertIn("libraries/forge/helpers.lua constructs a new gh/git command head 'git status'", messages[0])

    def test_exec_argv_raw_heads_are_flagged_outside_adapters(self) -> None:
        source = (
            'exec_argv({ argv = { "gh", "issue", "view", tostring(n) }, timeout = 30 })\n'
            'exec_argv({ timeout = 30, argv = { "git", "-C", repo, "status", "--short" } })\n'
        )
        heads = check_repo.gh_git_adapter.command_heads(source)

        self.assertEqual(heads, {"gh issue", "git status"})

    def test_exec_argv_raw_heads_respect_adapter_exemption(self) -> None:
        messages = self.messages({
            "libraries/forge/github/issue.lua": 'exec_argv({ argv = { "gh", "issue", "view", "1" } })\n',
            "libraries/forge/git/exec.lua": 'exec_argv({ argv = { "git", "status" } })\n',
            "libraries/forge/helpers.lua": 'exec_argv({ argv = { "git", "status" } })\n',
        })

        self.assertEqual(len(messages), 1)
        self.assertIn("libraries/forge/helpers.lua constructs a new gh/git command head 'git status'", messages[0])

    def test_check_repo_wrapper_loads_allowlist_and_prefixes_violations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "packages" / "example"
            migration = root / "migration"
            package.mkdir(parents=True)
            migration.mkdir()
            (package / "core.lua").write_text('return "gh issue list"\n', encoding="utf-8")
            (migration / "gh-git-adapter.allowlist").write_text(
                "packages/example/core.lua:\n"
                "  - gh issue\n",
                encoding="utf-8",
            )

            violations: list[str] = []
            check_repo.check_gh_git_adapter_ratchet(root, violations)
            self.assertEqual(violations, [])

            (package / "core.lua").write_text('return "gh pr view"\n', encoding="utf-8")
            check_repo.check_gh_git_adapter_ratchet(root, violations)

        self.assertEqual(len(violations), 2)
        self.assertTrue(all(message.startswith("G-ADAPTER: ") for message in violations))
        self.assertIn("constructs a new gh/git command head 'gh pr'", violations[0])
        self.assertIn("no longer constructs 'gh issue'", violations[1])


if __name__ == "__main__":
    unittest.main()
