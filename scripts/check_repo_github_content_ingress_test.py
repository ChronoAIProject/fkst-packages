#!/usr/bin/env python3
"""Tests for GitHub authored-content ingress ratchet."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from check_repo_test import load_check_repo


check_repo = load_check_repo()


class GithubContentIngressGuardTest(unittest.TestCase):
    def run_guard(self, files: dict[str, str]) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for relpath, source in files.items():
                path = root / relpath
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")
            violations: list[str] = []
            check_repo.check_github_content_ingress(root, violations)
            return violations

    def base_files(self) -> dict[str, str]:
        return {
            "libraries/forge/github/exec.lua": """
local content_filter = require("forge.github.content_filter")
local stdout_policy = require("forge.github.stdout_policy")
local function f(result, policy)
  if stdout_policy.is_content_json(policy) then
    return content_filter.filter_gh_content_json(result.stdout, {}, {})
  end
end
""",
            "libraries/devloop/gh_exec.lua": """
local content_filter = require("forge.github.content_filter")
local stdout_policy = require("forge.github.stdout_policy")
local function f(result, policy)
  if stdout_policy.is_content_json(policy) then
    return content_filter.filter_gh_content_json(result.stdout, {}, {})
  end
end
""",
        }

    def test_allows_two_mediated_wrappers_and_declared_policy(self) -> None:
        files = self.base_files()
        files["libraries/forge/github/issue.lua"] = """
function M.install(handle)
  return handle._exec({"gh", "issue", "view", "1"}, 30, "gh issue view", stdout_policy.content_json("issue_view"))
end
"""
        self.assertEqual(self.run_guard(files), [])

    def test_requires_both_wrappers_to_filter(self) -> None:
        files = self.base_files()
        files["libraries/devloop/gh_exec.lua"] = "local stdout_policy = require('forge.github.stdout_policy')\n"
        violations = self.run_guard(files)
        self.assertEqual(len(violations), 2)
        self.assertTrue(all("G-GITHUB-CONTENT-INGRESS" in item for item in violations))
        self.assertTrue(all("libraries/devloop/gh_exec.lua" in item for item in violations))

    def test_rejects_missing_stdout_policy_on_authored_read(self) -> None:
        files = self.base_files()
        files["libraries/forge/github/issue.lua"] = """
function M.install(handle)
  return handle._exec({"gh", "issue", "view", "1"}, 30, "gh issue view")
end
"""
        violations = self.run_guard(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("must declare a stdout_policy", violations[0])

    def test_rejects_third_raw_gh_exec_argv_egress(self) -> None:
        files = self.base_files()
        files["packages/github-devloop/core/raw.lua"] = """
function M.bad()
  return exec_argv({ argv = { "gh", "api", "repos/o/r/issues/1" }, timeout = 30 })
end
"""
        violations = self.run_guard(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("raw gh exec_argv egress", violations[0])


if __name__ == "__main__":
    unittest.main()
