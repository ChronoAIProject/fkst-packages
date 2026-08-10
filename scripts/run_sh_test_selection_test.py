#!/usr/bin/env python3
"""Execution tests specific to graph-derived affected-test selection."""

from __future__ import annotations

import unittest
from pathlib import Path

from run_sh_test_affected_test import (
    TestAffectedHarness,
    result_marker,
    result_markers,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
TEST_SELECTION_GATE_UNITS = (
    'python3 -B "$ROOT/scripts/run_sh_test_selection_test.py"',
    'python3 -B "$ROOT/scripts/test_selection_test.py"',
    'python3 -B "$ROOT/scripts/check_repo_test_selection_test.py"',
    'python3 -B "$ROOT/scripts/check_repo_test_selection.py"',
)


class RunShTestSelectionTest(unittest.TestCase):
    def test_check_registers_all_test_selection_gate_units(self) -> None:
        source = (REPO_ROOT / "scripts" / "run.sh").read_text(encoding="utf-8")
        for unit in TEST_SELECTION_GATE_UNITS:
            with self.subTest(unit=unit):
                self.assertIn(unit, source)

    def test_repo_only_runs_one_check_and_no_package_units(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "cmd_check() { printf '%s\\n' check >> \"$ROOT/check-count\"; return 0; }\n"
                "main test --repo-only"
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual((h.root / "check-count").read_text(encoding="utf-8"), "check\n")
            self.assertEqual(result_markers(result), [result_marker("PASS", "NONE")])
            self.assertIn("narrowed local test: not the CI gate", result.stdout)
            self.assertIn("skipped package suites", result.stdout)
            self.assertNotIn("=== self-test ===", result.stdout)
            self.assertNotIn("=== sdk-primitives ===", result.stdout)
            self.assertNotIn("=== consensus ===", result.stdout)
            self.assertNotIn("=== github-devloop ===", result.stdout)
        finally:
            h.close()

    def test_applies_graph_derived_path_rules(self) -> None:
        cases = (
            ("libraries/devloop/extra.lua", "changed\n", ["test github-devloop"]),
            ("scripts/helper.sh", "changed\n", ["test --repo-only"]),
            (".github/workflows/ci.yml", "changed\n", ["test --repo-only"]),
            ("scripts/test_parallel.sh", "# changed runner\n", ["test"]),
            ("fkst.workspace.toml", "changed\n", ["test"]),
        )
        for rel, content, expected in cases:
            with self.subTest(path=rel):
                h = TestAffectedHarness()
                try:
                    h._write(rel, content)

                    result = h.run()

                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    self.assertEqual(h.runner_args(), expected)
                finally:
                    h.close()

    def test_dependency_planner_failures_fall_back_to_full(self) -> None:
        cases = ((7, None), (0, "not-json"), (0, '{"ok":false,"units":[]}'))
        for deps_exit, deps_output in cases:
            with self.subTest(deps_exit=deps_exit, deps_output=deps_output):
                h = TestAffectedHarness()
                try:
                    h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

                    result = h.run(deps_exit=deps_exit, deps_output=deps_output)

                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    self.assertEqual(h.runner_args(), ["test"])
                finally:
                    h.close()

    def test_r100_script_rename_reports_source_and_destination(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write(
                "packages/github-devloop/core.lua",
                'return {checker = "scripts/helper.sh"}\n',
            )
            h._git("add", "packages/github-devloop/core.lua")
            h._git("commit", "-m", "reference helper")
            h._git("mv", "scripts/helper.sh", "scripts/helper-renamed.sh")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test github-devloop"])
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
