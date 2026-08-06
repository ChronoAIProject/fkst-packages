#!/usr/bin/env python3
"""Tests for the codex timeout resolver guard."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


def load_module(name: str):
    path = Path(__file__).with_name(name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


check_repo = load_module("check_repo")
check_repo_codex_timeout = load_module("check_repo_codex_timeout")


class CodexTimeoutLiteralGuardTest(unittest.TestCase):
    def literal_lines(self, source: str) -> list[int]:
        return check_repo_codex_timeout.codex_timeout_literal_lines(source, check_repo.strip_lua_comments_and_strings)

    def repository_violations(self, rel_path: str, source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / rel_path
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            return check_repo_codex_timeout.repository_messages(
                root,
                check_repo.package_lua_files,
                check_repo.read_text,
                check_repo.rel,
                check_repo.strip_lua_comments_and_strings,
            )

    def test_detects_spawn_codex_numeric_timeout_literal(self) -> None:
        source = """
local result = spawn_codex_sync({
  prompt = prompt,
  timeout = 2 * 60 * 60,
})
"""
        self.assertEqual(self.literal_lines(source), [4])

    def test_detects_workflow_dispatch_numeric_timeout_literal(self) -> None:
        source = """
local result = workflow_codex.dispatch(identity, {
  prompt = prompt,
  timeout = 2 * 60 * 60,
  sync = true,
})
"""
        self.assertEqual(self.literal_lines(source), [4])

    def test_detects_numeric_timeout_assignment_before_codex_spawn(self) -> None:
        source = """
local opts = workflow_codex.judgment_codex_opts(prompt, ".")
opts.timeout = 3600
return spawn_codex_sync(opts)
"""
        self.assertEqual(self.literal_lines(source), [3])

    def test_detects_codex_timeout_constant_default(self) -> None:
        source = """
local codex_timeout_seconds = 60 * 60
local opts = workflow_codex.judgment_codex_opts(prompt, ".")
opts.timeout = codex_timeout_seconds
return spawn_codex_sync(opts)
"""
        self.assertEqual(self.literal_lines(source), [2])

    def test_detects_numeric_timeout_alias_before_codex_spawn(self) -> None:
        source = """
local timeout_seconds = 3600
local opts = workflow_codex.judgment_codex_opts(prompt, ".")
opts.timeout = timeout_seconds
return spawn_codex_sync(opts)
"""
        self.assertEqual(self.literal_lines(source), [2])

    def test_ignores_comments_strings_and_non_codex_timeouts(self) -> None:
        source = """
-- spawn_codex_sync({ timeout = 3600 })
local note = "spawn_codex_sync({ timeout = 3600 })"
return exec_sync({ cmd = "pwd", timeout = 30 })
"""
        self.assertEqual(self.literal_lines(source), [])

    def test_repository_check_scans_production_package_lua_only(self) -> None:
        violations = self.repository_violations(
            "packages/example/departments/worker/main.lua",
            "return spawn_codex_sync({ prompt = prompt, timeout = 3600 })\n",
        )
        self.assertEqual(len(violations), 1)
        self.assertIn("production codex timeout defaults", violations[0])

        test_violations = self.repository_violations(
            "packages/example/tests/worker_test.lua",
            "return spawn_codex_sync({ prompt = prompt, timeout = 3600 })\n",
        )
        self.assertEqual(test_violations, [])


if __name__ == "__main__":
    unittest.main()
