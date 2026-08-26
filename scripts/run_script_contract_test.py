#!/usr/bin/env python3
"""Contract tests for scripts/run.sh repository-check orchestration."""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


def load_check_repo():
    path = Path(__file__).with_name("check_repo.py")
    spec = importlib.util.spec_from_file_location("check_repo", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load check_repo.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


check_repo = load_check_repo()


class RunScriptContractTest(unittest.TestCase):
    def source(self) -> str:
        return Path(__file__).with_name("run.sh").read_text(encoding="utf-8")

    def test_the_runner_offers_no_supervise_entry(self) -> None:
        """Supervise is the deployment mechanism's entry, not this repository's.

        The rate-pool guard this used to assert lived inside `cmd_supervise_old`. Asserting the
        absence of the subcommand rather than deleting the case outright keeps the retirement
        witnessed: reintroducing a supervise entry here fails, instead of silently passing.
        """
        source = self.source()
        host_entry = Path(__file__).with_name("host_entry.sh").read_text(encoding="utf-8")

        self.assertNotIn("cmd_supervise", source)
        self.assertNotIn("scripts/run.sh supervise", source)
        self.assertNotIn("host_entry_cmd_supervise", host_entry)
        self.assertNotIn("check|test|supervise", host_entry)

    def test_python_repository_checks_do_not_write_bytecode_cache(self) -> None:
        source = self.source()
        expected = (
            "check_repo.py", "ratchet_base_test.py", "check_repo_fkst_layout.py", "check_repo_dedup_test.py",
            "check_repo_content_truncation_test.py", "check_repo_bot_login_mediation_test.py", "check_repo_fanout_only_test.py", "check_repo_coverage_test.py",
            "check_repo_integration_coverage_test.py", "check_repo_intake_default_surface_test.py", "check_repo_dead_letter_test.py", "check_repo_dead_locals_test.py", "check_repo_producer_liveness_test.py", "check_repo_monotone_gate_test.py", "check_repo_hidden_state_test.py",
            "check_repo_test_graphql.py", "check_repo_interface_test.py", "lua_coverage_to_lcov_test.py", "check_repo_test.py", "check_repo_github_content_ingress_test.py", "check_repo_error_class_test.py", "check_repo_library_error_class_test.py", "check_repo_dependency_cycle_test.py",
            "check_repo_std_dependency_model_test.py", "check_repo_devloop_installer_test.py", "check_repo_library_layering_test.py", "check_repo_saga_head_test.py",
            "check_repo_namespaced_queue_test.py", "check_repo_shell_out_to_self_test.py", "check_repo_fkst_layout_test.py",
            "bin_cache_test.py", "bin_bootstrap_test.py", "host_entry_test.py",
            "run_script_contract_test.py", "run_sh_coverage_test.py", "run_sh_test_affected_test.py", "board_test.py", "lifecycle_board_fact_test.py", "doctor_test.py", "ratchet_migration_slicer_test.py",
            "competence_gate_test.py", "test_parallel_test.py", "check_repo_restart_preflight_test.py",
        )
        for path in expected:
            self.assertIn(f'python3 -B "$ROOT/scripts/{path}"', source)
            self.assertNotIn(f'python3 "$ROOT/scripts/{path}"', source)

    def test_package_runtime_view_is_regenerated_from_source_packages(self) -> None:
        source = self.source()

        self.assertIn('SOURCE_PACKAGES_ROOT="$ROOT/packages"', source)
        self.assertIn('LOCAL_PACKAGES_ROOT="$FKST_DIR/local-packages"', source)
        self.assertIn('EXTERNAL_PACKAGES_ROOT="$FKST_DIR/packages"', source)
        self.assertIn('ln -sfn ../packages "$LOCAL_PACKAGES_ROOT"', source)
        # The enumeration is still driven from SOURCE_PACKAGES_ROOT; it is ordered by
        # test_units_longest_first rather than by the directory glob, so that the pool
        # dispatches its costliest unit first. The property frozen here is the source of
        # the package list, not the order.
        self.assertIn('done < <(test_units_longest_first "$SOURCE_PACKAGES_ROOT")', source)
        self.assertIn('pkg="$LOCAL_PACKAGES_ROOT/$name"', source)

    def test_full_test_blocks_on_repository_check_before_engine_resolution(self) -> None:
        source = self.source()

        self.assertIn("elif ! _chk_out=\"$(cmd_check 2>&1)\"; then", source)
        self.assertIn("printf '%s\\n' \"$_chk_out\"; return 1", source)
        self.assertLess(source.index("cmd_check"), source.index("resolve_bin; ensure_fresh_bin; cmd_test"))

    def test_standard_test_cannot_enable_engine_compatibility_from_ambient_env(self) -> None:
        root = Path(__file__).resolve().parents[1]
        script = f'''
source "{root / "scripts/run.sh"}"
local_iteration_result_arm() {{ :; }}
arm_test_deadline() {{ :; }}
cmd_check() {{ :; }}
resolve_bin() {{ :; }}
ensure_fresh_bin() {{ :; }}
cmd_test() {{ printf '%s:%s\n' "${{FKST_LIVENESS_ENGINE_COMPATIBILITY:-unset}}" "$*"; }}
cmd_test_affected() {{ printf '%s:%s\n' "${{FKST_LIVENESS_ENGINE_COMPATIBILITY:-unset}}" "test-affected"; }}
export FKST_LIVENESS_ENGINE_COMPATIBILITY=1
main test github-devloop
export FKST_LIVENESS_ENGINE_COMPATIBILITY=1
main test-affected
'''
        result = subprocess.run(
            ["/bin/bash", "-c", script],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["unset:github-devloop", "unset:test-affected"])

    def test_engine_compatibility_lane_requires_preprovisioned_binaries(self) -> None:
        root = Path(__file__).resolve().parents[1]
        script = f'''
source "{root / "scripts/run.sh"}"
cmd_test() {{ echo "unexpected package test"; }}
unset FKST_LIVENESS_PRE_ADVANCE_ENGINE_BIN FKST_LIVENESS_POST_ADVANCE_ENGINE_BIN
cmd_test_engine_compatibility
'''
        result = subprocess.run(
            ["/bin/bash", "-c", script],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("unexpected package test", result.stdout)
        self.assertIn("FKST_LIVENESS_PRE_ADVANCE_ENGINE_BIN", result.stderr)

    def test_engine_compatibility_lane_selects_only_github_devloop(self) -> None:
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            pre_bin = Path(tmp) / "pre" / "target" / "debug" / "fkst-framework"
            post_bin = Path(tmp) / "post" / "target" / "debug" / "fkst-framework"
            for path in (pre_bin, post_bin):
                path.parent.mkdir(parents=True)
                path.write_text("#!/bin/sh\n", encoding="utf-8")
                path.chmod(0o755)
            script = f'''
source "{root / "scripts/run.sh"}"
cmd_test() {{
  printf '%s:%s:%s:%s\n' \
    "$FKST_LIVENESS_ENGINE_COMPATIBILITY" \
    "$FKST_LIVENESS_PRE_ADVANCE_ENGINE_REF" \
    "$FKST_LIVENESS_POST_ADVANCE_ENGINE_REF" \
    "$*"
}}
liveness_engine_bin_ref() {{
  case "$1" in
    *pre*) printf '%s\n' "$FKST_LIVENESS_PRE_ADVANCE_ENGINE_REF" ;;
    *post*) printf '%s\n' "$FKST_LIVENESS_POST_ADVANCE_ENGINE_REF" ;;
  esac
}}
resolve_bin() {{ :; }}
ensure_fresh_bin() {{ :; }}
export FKST_LIVENESS_PRE_ADVANCE_ENGINE_BIN="{pre_bin}"
export FKST_LIVENESS_POST_ADVANCE_ENGINE_BIN="{post_bin}"
cmd_test_engine_compatibility
'''
            result = subprocess.run(
                ["/bin/bash", "-c", script],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        mode, pre_ref, post_ref, packages = result.stdout.strip().split(":")
        self.assertEqual(mode, "1")
        self.assertRegex(pre_ref, r"^[0-9a-f]{40}$")
        self.assertRegex(post_ref, r"^[0-9a-f]{40}$")
        self.assertNotEqual(pre_ref, post_ref)
        self.assertEqual(packages, "github-devloop")

    def test_liveness_compatibility_test_has_no_bootstrap_path(self) -> None:
        root = Path(__file__).resolve().parents[1]
        source = (
            root / "packages/github-devloop/tests/run_graph_liveness_failure_domain_test.lua"
        ).read_text(encoding="utf-8")

        self.assertNotIn("bootstrap_bin_on_total_miss", source)
        self.assertIn("FKST_LIVENESS_PRE_ADVANCE_ENGINE_BIN", source)
        self.assertIn("FKST_LIVENESS_POST_ADVANCE_ENGINE_BIN", source)

    def test_help_names_the_explicit_engine_compatibility_lane(self) -> None:
        root = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            ["/bin/bash", "scripts/run.sh", "help"],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("scripts/run.sh test-engine-compatibility", result.stdout)

    def test_repository_check_maps_producer_typed_exit_codes(self) -> None:
        root = Path(__file__).resolve().parents[1]
        for exit_code, expected in ((12, "FAIL:TOOLCHAIN"), (13, "FAIL:INFRASTRUCTURE")):
            with self.subTest(exit_code=exit_code):
                script = f'''
source "{root / "scripts/run.sh"}"
competence_gate_base_ref() {{ printf '%s\n' dev; }}
run_units_parallel() {{ RUN_UNITS_FAIL_CODES="{exit_code}"; return 1; }}
cmd_check >/dev/null 2>&1 || true
printf '%s:%s\n' "$LOCAL_ITERATION_RESULT_VERDICT" "$LOCAL_ITERATION_RESULT_FAULT_CLASS"
'''
                result = subprocess.run(
                    ["/bin/bash", "-c", script],
                    cwd=root,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_full_test_fails_on_g1_before_bin_resolution(self) -> None:
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            probe = Path(tmp) / "repo"
            scripts = probe / "scripts"
            pkg = probe / "packages" / "oversized"
            contract = probe / "libraries" / "contract"
            scripts.mkdir(parents=True)
            pkg.mkdir(parents=True)
            contract.mkdir(parents=True)

            for name in ("run.sh", "test_affected.sh", "test_affected.py", "test_parallel.sh", "test_coverage.sh", "test_deadline.sh", "test_engine_compatibility.sh", "run_department.sh", "bin_bootstrap.sh", "local_iteration_result.sh", "run_bin.sh", "host_entry.sh", "composed_manifest.sh", "check_repo.py", "check_repo_bot_login_mediation.py", "check_repo_config.py", "check_repo_runner.py", "check_repo_codex_timeout.py", "check_repo_content_truncation.py", "check_repo_fanout_only.py", "check_repo_coverage.py", "check_repo_cross_package.py", "check_repo_dead_letter.py", "check_repo_dead_locals.py", "check_repo_dept_failure_surface.py", "check_repo_dependency_cycle.py", "check_repo_devloop_godlib.py", "check_repo_devloop_decouple.py", "check_repo_devloop_installer.py", "check_repo_service_locator.py", "check_repo_ambient_surface.py", "check_repo_core_param.py", "check_repo_dedup.py", "check_repo_error_class.py", "check_repo_gh_egress.py", "check_repo_gh_git_adapter.py", "check_repo_gh_handle_construction.py", "check_repo_github_content_ingress.py", "check_repo_hidden_state.py", "check_repo_ingress.py", "check_repo_intake_default_surface.py", "check_repo_intake_routing.py", "check_repo_intent_bounded_replay.py", "check_repo_intent_bounded_replay_trace_catalog.py", "check_repo_integration_coverage.py", "check_repo_library_layering.py", "check_repo_live_run_dispatch.py", "check_repo_lock_scope.py", "check_repo_lower_injected_m.py", "check_repo_lua.py", "check_repo_monotone_gate.py", "check_repo_namespaced_queue.py", "check_repo_ownership_gate.py", "check_repo_pagination.py", "check_repo_perm.py", "check_repo_producer_liveness.py", "check_repo_restart_lifecycle.py", "check_repo_saga_handler.py", "check_repo_saga_head.py", "check_repo_saga_split.py", "check_repo_shell_out_to_self.py", "check_repo_std_dependency_model.py", "check_repo_version_suffix.py", "ratchet_base.py"):
                shutil.copy2(root / "scripts" / name, scripts / name)
            shutil.copy2(root / "scripts/check_repo_restart_preflight.py", scripts / "check_repo_restart_preflight.py")
            shutil.copy2(root / "libraries/contract/error_facts.lua", contract / "error_facts.lua")
            for name in ("check_repo_coverage_test.py", "check_repo_integration_coverage_test.py", "check_repo_intake_default_surface_test.py", "check_repo_dead_letter_test.py", "check_repo_dead_locals_test.py", "check_repo_dedup_test.py", "check_repo_content_truncation_test.py", "check_repo_bot_login_mediation_test.py", "check_repo_fanout_only_test.py", "check_repo_codex_timeout_test.py", "check_repo_dependency_cycle_test.py", "check_repo_producer_liveness_test.py", "check_repo_monotone_gate_test.py", "check_repo_hidden_state_test.py", "check_repo_test_graphql.py", "check_repo_interface_test.py", "lua_coverage_to_lcov_test.py", "check_repo_test.py", "check_repo_github_content_ingress_test.py", "check_repo_error_class_test.py", "check_repo_library_error_class_test.py", "check_repo_library_layering_test.py", "check_repo_std_dependency_model_test.py", "check_repo_devloop_installer_test.py", "check_repo_gh_egress_test.py", "check_repo_gh_handle_construction_test.py", "check_repo_restart_lifecycle_test.py", "check_repo_saga_head_test.py", "check_repo_namespaced_queue_test.py", "check_repo_shell_out_to_self_test.py", "check_repo_fkst_layout.py", "check_repo_fkst_layout_test.py", "bin_cache_test.py", "bin_bootstrap_test.py", "warm_pinned_bin_test.py", "host_entry_test.py", "run_sh_coverage_test.py", "run_sh_test_affected_test.py", "composed_manifest_test.py", "board_test.py", "lifecycle_board_fact_test.py", "doctor_test.py", "ratchet_migration_slicer_test.py", "run_script_contract_test.py", "ratchet_base_test.py", "competence_gate_test.py", "test_parallel_test.py"):
                (scripts / name).write_text("#!/usr/bin/env python3\nraise SystemExit(0)\n", encoding="utf-8")
            (scripts / "check_repo_restart_preflight_test.py").write_text(
                "#!/usr/bin/env python3\nraise SystemExit(0)\n", encoding="utf-8"
            )

            intent_replay = scripts / "intent_bounded_replay"
            intent_replay.mkdir()
            for name in ("normalize.py", "compare.py", "semantic_tree.py", "delivery_authorization.py"):
                shutil.copy2(root / "scripts" / "intent_bounded_replay" / name, intent_replay / name)
            migration = probe / "migration"
            migration.mkdir()
            thinking_corpus = migration / "intent_bounded_replay" / "corpus"
            thinking_corpus.mkdir(parents=True)
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/thinking.json",
                thinking_corpus / "thinking.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/issue-reconcile.json",
                thinking_corpus / "issue-reconcile.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/loop-plain.json",
                thinking_corpus / "loop-plain.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/implement-activation.json",
                thinking_corpus / "implement-activation.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/awaiting-pr.json",
                thinking_corpus / "awaiting-pr.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/timeout-reconcile.json",
                thinking_corpus / "timeout-reconcile.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/observe-issue-entry.json",
                thinking_corpus / "observe-issue-entry.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/pr-review-result.json",
                thinking_corpus / "pr-review-result.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/pr-review-meta.json",
                thinking_corpus / "pr-review-meta.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/pr-fix.json",
                thinking_corpus / "pr-fix.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/pr-review-activation.json",
                thinking_corpus / "pr-review-activation.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/observe-pr-fix.json",
                thinking_corpus / "observe-pr-fix.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/pr-review-loop.json",
                thinking_corpus / "pr-review-loop.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/pr-fix-reconcile.json",
                thinking_corpus / "pr-fix-reconcile.json",
            )
            shutil.copy2(
                root / "migration/intent_bounded_replay/corpus/pr-merge.json",
                thinking_corpus / "pr-merge.json",
            )
            (migration / "intent-bounded-replay.allowlist").write_text(
                "# R9 intent-bounded-replay: zero behavior-change intent-diffs during refactor.\n",
                encoding="utf-8",
            )
            intent_diffs = migration / "intent-diffs"
            intent_diffs.mkdir()
            (intent_diffs / ".gitkeep").write_text("", encoding="utf-8")

            core_lines = [
                "local M = {}",
                "function M.persistence_class() return \"stateless_adapter\" end",
                "return M",
            ]
            core_lines.extend("-- filler" for _ in range(check_repo.LINE_LIMIT + 1 - len(core_lines)))
            (pkg / "core.lua").write_text("\n".join(core_lines) + "\n", encoding="utf-8")

            env = os.environ.copy()
            env["BIN"] = str(probe / "missing-fkst-framework")
            result = subprocess.run(
                ["/bin/bash", "scripts/run.sh", "test"],
                cwd=probe,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        combined = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repository check failed:", combined)
        self.assertIn("G1: packages/oversized/core.lua has 1001 lines; limit is 1000", combined)
        self.assertNotIn("explicit BIN is not executable", combined)


if __name__ == "__main__":
    unittest.main()
