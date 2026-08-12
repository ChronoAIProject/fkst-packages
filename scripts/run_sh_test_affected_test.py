#!/usr/bin/env python3
"""Execution tests for scripts/run.sh test-affected.

The probe-repository harness these drive lives in run_sh_test_affected_harness.py.
"""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

from run_sh_test_affected_harness import (
    REPO_ROOT,
    RESULT_PREFIX,
    TestAffectedHarness,
    result_marker,
    result_markers,
)

class RunShTestAffectedTest(unittest.TestCase):
    def test_scopes_to_uncommitted_changed_package(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                h.runner_args(),
                ["test frontend-devloop github-devloop"],
            )
            self.assertEqual(result_markers(result), [result_marker("PASS", "NONE")])
        finally:
            h.close()

    def test_preserves_producer_declared_semantic_failure(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(runner_exit=1, runner_result="FAIL:SEMANTIC")

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "SEMANTIC")],
            )
            self.assertEqual(
                h.runner_args(),
                ["test frontend-devloop github-devloop"],
            )
        finally:
            h.close()

    def test_failed_runner_replays_stdout_diagnostic_to_stderr(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(
                runner_exit=1,
                runner_result="FAIL:SEMANTIC",
                runner_stdout="G-RESTART-PREFLIGHT: checker-checked-cochange",
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertIn(
                "G-RESTART-PREFLIGHT: checker-checked-cochange",
                result.stderr,
            )
            self.assertNotIn(
                "G-RESTART-PREFLIGHT: checker-checked-cochange",
                result.stdout,
            )
        finally:
            h.close()

    def test_untyped_affected_runner_failure_remains_unknown(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(runner_exit=2, runner_result=None)

            self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("UNKNOWN", "UNKNOWN")],
            )
            self.assertEqual(
                h.runner_args(),
                ["test frontend-devloop github-devloop"],
            )
        finally:
            h.close()

    def test_default_test_declares_failed_report_as_semantic_failure(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_default_test("semantic-fail")

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "SEMANTIC")],
            )
        finally:
            h.close()

    def test_default_test_leaves_unreported_engine_failure_unknown(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_default_test("infrastructure-fail")

            self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("UNKNOWN", "UNKNOWN")],
            )
        finally:
            h.close()

    def test_default_test_types_unknown_flag_as_configuration(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "cmd_check() { return 0; }\nmain test --not-a-test-flag"
            )

            self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "CONFIGURATION")],
            )
        finally:
            h.close()

    def test_default_test_types_missing_package_target_as_configuration(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "cmd_check() { return 0; }\nmain test missing-package"
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "CONFIGURATION")],
            )
        finally:
            h.close()

    def test_default_test_types_bin_resolution_failure_as_toolchain(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "cmd_check() { return 0; }\n"
                "resolve_bin_contract() { RESOLVE_BIN_ERROR='fixture BIN missing'; return 1; }\n"
                "main test github-devloop"
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "TOOLCHAIN")],
            )
        finally:
            h.close()

    def test_default_test_leaves_implicit_errexit_unknown(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "cmd_check() { return 0; }\n"
                "resolve_bin() { :; }\n"
                "ensure_fresh_bin() { :; }\n"
                "cmd_test() { false; }\n"
                "main test"
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("UNKNOWN", "UNKNOWN")],
            )
        finally:
            h.close()

    def test_default_test_leaves_unclassified_check_failure_unknown(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "cmd_check() { printf '%s\\n' 'python3: command not found' >&2; return 127; }\n"
                "main test github-devloop"
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("UNKNOWN", "UNKNOWN")],
            )
        finally:
            h.close()

    def test_default_test_preserves_g5_failure_as_semantic(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/tests/unreported_test.lua", "return {}\n")

            result = h.run_test_process(
                "cmd_check() { return 0; }\n"
                "cmd_test_composed() { return 0; }\n"
                "enforce_lua_coverage_ratchet() { return 0; }\n"
                "main test"
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "SEMANTIC")],
            )
            self.assertIn("G5 engine test coverage failed", result.stderr + result.stdout)
        finally:
            h.close()

    def test_result_arm_failure_still_emits_one_infrastructure_result(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "mktemp() {\n"
                "  case \"$*\" in\n"
                "    *fkst-local-result-state*) return 1 ;;\n"
                "    *) command mktemp \"$@\" ;;\n"
                "  esac\n"
                "}\n"
                "main test"
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "INFRASTRUCTURE")],
            )
        finally:
            h.close()

    def test_result_output_file_is_not_inherited_by_test_descendants(self) -> None:
        h = TestAffectedHarness()
        try:
            result_file = Path(h.tmp) / "local-iteration-result"
            result = h.run_test_process(
                "cmd_check() { [ -z \"${FKST_LOCAL_ITERATION_RESULT_FILE:-}\" ]; }\n"
                "resolve_bin() { :; }\n"
                "ensure_fresh_bin() { :; }\n"
                "cmd_test() { local_iteration_result_pass; }\n"
                "main test",
                result_file=result_file,
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(result_markers(result), [])
            self.assertEqual(
                result_file.read_text(encoding="utf-8"),
                result_marker("PASS", "NONE") + "\n",
            )
        finally:
            h.close()

    def test_markerless_affected_runner_success_fails_closed(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(runner_result=None)

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("UNKNOWN", "UNKNOWN")],
            )
        finally:
            h.close()

    def test_batched_affected_run_checks_once_and_executes_every_unit(self) -> None:
        packages = tuple(
            path.parent.name for path in sorted((REPO_ROOT / "packages").glob("*/fkst.toml"))
        )
        built_in_packages = {"consensus", "frontend-devloop", "github-devloop"}
        h = TestAffectedHarness(
            tuple(package for package in packages if package not in built_in_packages)
        )
        try:
            for package in packages:
                h._write(f"packages/{package}/core.lua", "return {changed = true}\n")

            result = h.run(use_run_sh=True)

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(result_markers(result), [result_marker("PASS", "NONE")])
            self.assertEqual(h.check_calls(), ["check"])
            self.assertEqual(h.runner_args(), ["test " + " ".join(sorted(packages))])
            self.assertEqual(sorted(h.engine_packages()), sorted(packages))
        finally:
            h.close()

    def test_batched_package_failure_runs_all_units_then_fails(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/consensus/core.lua", "return {changed = true}\n")
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(use_run_sh=True, engine_fail_package="consensus")

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "SEMANTIC")],
            )
            self.assertEqual(
                sorted(h.engine_packages()),
                ["consensus", "frontend-devloop", "github-devloop"],
            )
        finally:
            h.close()

    def test_invalid_target_fails_before_any_package_unit(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "cmd_check() { printf '%s\\n' check >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "main test missing-package consensus"
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "CONFIGURATION")],
            )
            self.assertEqual(h.engine_packages(), [])
        finally:
            h.close()

    def test_single_and_zero_target_behaviors_are_unchanged(self) -> None:
        h = TestAffectedHarness()
        try:
            single = h.run_test_process(
                "cmd_check() { printf '%s\\n' check >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "cmd_test_composed() { printf '%s\\n' composed >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "enforce_lua_coverage_ratchet() { printf '%s\\n' coverage >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "check_test_file_coverage() { printf '%s\\n' test-files >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "main test consensus"
            )

            self.assertEqual(single.returncode, 0, single.stderr + single.stdout)
            self.assertEqual(h.check_calls(), ["check"])
            self.assertEqual(h.engine_packages(), ["consensus"])
        finally:
            h.close()

        h = TestAffectedHarness()
        try:
            full = h.run_test_process(
                "cmd_check() { printf '%s\\n' check >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "cmd_test_composed() { printf '%s\\n' composed >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "enforce_lua_coverage_ratchet() { printf '%s\\n' coverage >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "check_test_file_coverage() { printf '%s\\n' test-files >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "main test"
            )

            self.assertEqual(full.returncode, 0, full.stderr + full.stdout)
            self.assertEqual(
                h.check_calls(),
                ["check", "composed", "coverage", "test-files"],
            )
            self.assertEqual(
                sorted(h.engine_packages()),
                ["consensus", "frontend-devloop", "github-devloop"],
            )
        finally:
            h.close()

    def test_works_without_integration_branch_env(self) -> None:
        # Regression guard (#1619 follow-up): the spawned implement/fix codex
        # environment does NOT carry FKST_DEVLOOP_INTEGRATION_BRANCH. The earlier
        # base-ref derivation fail-closed here, breaking every implement. Scope
        # must derive purely from the worktree's uncommitted edits.
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(with_branch_env=False)

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                h.runner_args(),
                ["test frontend-devloop github-devloop"],
            )
        finally:
            h.close()

    def test_committed_only_changes_fall_back_to_full(self) -> None:
        # Codex verifies before committing, so its edits are uncommitted at verify
        # time. If nothing is uncommitted (e.g. already committed), fall back to the
        # full suite rather than silently testing nothing.
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {committed = true}\n")
            h._git("add", ".")
            h._git("commit", "-m", "committed change")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test"])
        finally:
            h.close()

    def test_library_change_selects_reverse_dependency_closure(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("libraries/devloop/extra.lua", "return {}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                h.runner_args(),
                ["test frontend-devloop github-devloop"],
            )
        finally:
            h.close()

    def test_library_dependency_change_reaches_package_consumers(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("libraries/workflow/extra.lua", "return {}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                h.runner_args(),
                ["test consensus frontend-devloop github-devloop"],
            )
        finally:
            h.close()

    def test_unknown_library_falls_back_to_full(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("libraries/unknown/extra.lua", "return {}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test"])
        finally:
            h.close()

    def test_runs_full_for_independently_broad_paths(self) -> None:
        broad_paths = (
            "scripts/helper.sh",
            ".github/workflows/ci.yml",
            "fkst.workspace.toml",
        )
        for rel in broad_paths:
            h = TestAffectedHarness()
            try:
                h._write(rel, "changed\n")

                result = h.run()

                self.assertEqual(result.returncode, 0, rel + "\n" + result.stderr + result.stdout)
                self.assertEqual(h.runner_args(), ["test"], rel)
            finally:
                h.close()

    def test_runs_full_for_dogfood_operator_paths(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write(".claude/skills/dogfood-github-devloop/dogfood.sh", "#!/usr/bin/env bash\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test"])
        finally:
            h.close()

    def test_runs_changed_packages_in_one_sorted_invocation(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/consensus/core.lua", "return {changed = true}\n")
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                h.runner_args(),
                ["test consensus frontend-devloop github-devloop"],
            )
        finally:
            h.close()

    def test_untracked_new_package_file_is_counted(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/new_module.lua", "return {}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                h.runner_args(),
                ["test frontend-devloop github-devloop"],
            )
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
