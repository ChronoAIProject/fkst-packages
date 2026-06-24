#!/usr/bin/env python3
"""Tests for the shell-out-to-self migration ratchet."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


scripts_dir = Path(__file__).resolve().parent
check_repo = load_module("check_repo", scripts_dir / "check_repo.py")
shell_out = check_repo.check_repo_shell_out_to_self


class ShellOutToSelfRatchetTest(unittest.TestCase):
    def sites(self, source: str) -> set[str]:
        return shell_out.source_sites(
            "packages/example/core.lua",
            source,
            check_repo.strip_lua_comments_and_strings,
            check_repo.lua_string_literals,
        )

    def test_detects_exec_argv_to_framework_observe(self) -> None:
        source = """
local bin = "/tmp/fkst-framework"
local result = exec_argv({ argv = { bin, "observe", "--json" }, timeout = 30 })
"""
        sites = self.sites(source)

        self.assertEqual(sites, {"packages/example/core.lua:line=3:argv:observe"})

    def test_detects_run_argv_to_named_framework_test(self) -> None:
        source = """
local result = run_argv({
  argv = { "fkst-framework", "test", "--package-root", root },
})
"""
        sites = self.sites(source)

        self.assertEqual(sites, {"packages/example/core.lua:line=2:argv:test"})

    def test_detects_string_shell_out_to_bin_observe(self) -> None:
        source = """
local cmd = "$BIN observe --json"
"""
        sites = self.sites(source)

        self.assertEqual(sites, {"packages/example/core.lua:line=2:string:observe"})

    def test_ignores_comments(self) -> None:
        source = """
-- exec_argv({ argv = { bin, "observe", "--json" } })
"""
        self.assertEqual(self.sites(source), set())

    def test_allowlist_and_stale_entries(self) -> None:
        site = "packages/example/core.lua:line=2:argv:observe"
        current = {site}

        self.assertEqual(shell_out.ratchet_messages(current, {site}), [])
        messages = shell_out.ratchet_messages(set(), {site})
        self.assertEqual(len(messages), 1)
        self.assertIn("no longer detected", messages[0])


if __name__ == "__main__":
    unittest.main()
