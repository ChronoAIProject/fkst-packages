#!/usr/bin/env python3
"""Execution tests for scripts/run.sh test-affected."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RESULT_PREFIX = "FKST_LOCAL_ITERATION_RESULT:v2:"


def result_marker(verdict: str, fault_class: str) -> str:
    return f"{RESULT_PREFIX}{verdict}:{fault_class}"


def result_markers(result: subprocess.CompletedProcess[str]) -> list[str]:
    return [
        line
        for line in (result.stdout + result.stderr).splitlines()
        if line.startswith("FKST_LOCAL_ITERATION_RESULT:")
    ]


def _robust_rmtree(path: str) -> None:
    """Remove a temp dir, tolerating a transient concurrent writer under .git.

    rmtree is not atomic (scandir -> unlink -> rmdir); if anything writes into a
    directory between its final scandir and rmdir, rmdir fails with ENOTEMPTY.
    The fixture builds a git repo and runs git inside it, so a detached git
    background process (e.g. auto gc / maintenance) briefly repopulating .git is
    the likely writer racing cleanup -- observed only on CI as a non-deterministic
    OSError [Errno 39] Directory not empty: '.git'. Retry until the transient
    writer settles; this is the standard cleanup shape CPython's own
    test.support.rmtree and pip use for exactly this inherent race. On any OSError
    the tree is done only when the *root* is gone: a vanished nested entry can
    raise FileNotFoundError on Python < 3.13 while the root still exists.
    """
    for attempt in range(8):
        try:
            shutil.rmtree(path)
            return
        except OSError:
            if not os.path.exists(path):
                return
            if attempt == 7:
                raise
            time.sleep(0.1)


class TestAffectedHarness:
    def __init__(self, extra_packages: tuple[str, ...] = ()) -> None:
        # mkdtemp (not TemporaryDirectory) so cleanup has a single explicit owner
        # via _robust_rmtree. Construction happens before the caller's
        # try/finally: h.close(), so clean up here if any construction step fails.
        self.tmp = tempfile.mkdtemp()
        try:
            self.root = Path(self.tmp) / "repo"
            self.scripts = self.root / "scripts"
            self.log = Path(self.tmp) / "runner.log"
            self.check_log = Path(self.tmp) / "check.log"
            self.engine_log = Path(self.tmp) / "engine.log"
            self.runner = Path(self.tmp) / "runner.sh"
            self.engine = Path(self.tmp) / "fkst-framework"
            self.root.mkdir()
            self.scripts.mkdir()
            for name in (
                "run.sh",
                "bin_bootstrap.sh",
                "local_iteration_result.sh",
                "run_bin.sh",
                "host_run.sh",
                "host_entry.sh",
                "composed_manifest.sh",
                "composed_conformance.sh",
                "test_parallel.sh",
                "test_deadline.sh",
                "run_department.sh",
                "check_repo_intake_routing.py",
                "intake_policy_slots.json",
            ):
                shutil.copy2(REPO_ROOT / "scripts" / name, self.scripts / name)
            test_affected = REPO_ROOT / "scripts" / "test_affected.sh"
            if test_affected.exists():
                shutil.copy2(test_affected, self.scripts / "test_affected.sh")
            shutil.copy2(
                REPO_ROOT / "scripts" / "test_affected.py",
                self.scripts / "test_affected.py",
            )
            local_iteration_result = REPO_ROOT / "scripts" / "local_iteration_result.sh"
            if local_iteration_result.exists():
                shutil.copy2(local_iteration_result, self.scripts / "local_iteration_result.sh")
            self.runner.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" >> \"$FKST_TEST_AFFECTED_LOG\"\n"
                "if [ \"${FKST_TEST_AFFECTED_USE_RUN_SH:-}\" = 1 ]; then\n"
                "  . \"$FKST_TEST_REPO_ROOT/scripts/run.sh\"\n"
                "  cmd_check() { printf '%s\\n' check >> \"$FKST_TEST_CHECK_LOG\"; }\n"
                "  resolve_bin() { :; }\n"
                "  ensure_fresh_bin() { :; }\n"
                "  main \"$@\"\n"
                "  exit $?\n"
                "fi\n"
                "result=${FKST_TEST_AFFECTED_RUNNER_RESULT:-}\n"
                "if [ -n \"$result\" ]; then\n"
                "  marker=FKST_LOCAL_ITERATION_RESULT:v2:$result\n"
                "  if [ -n \"${FKST_LOCAL_ITERATION_RESULT_FILE:-}\" ]; then\n"
                "    printf '%s\\n' \"$marker\" > \"$FKST_LOCAL_ITERATION_RESULT_FILE\"\n"
                "  else\n"
                "    printf '%s\\n' \"$marker\" >&2\n"
                "  fi\n"
                "fi\n"
                "if [ -n \"${FKST_TEST_AFFECTED_RUNNER_STDOUT:-}\" ]; then\n"
                "  printf '%s\\n' \"$FKST_TEST_AFFECTED_RUNNER_STDOUT\"\n"
                "fi\n"
                "exit \"${FKST_TEST_AFFECTED_RUNNER_EXIT:-0}\"\n",
                encoding="utf-8",
            )
            self.runner.chmod(self.runner.stat().st_mode | stat.S_IXUSR)
            self.engine.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -eu

                    write_report() {
                      local path="$1" failed="$2"
                      mkdir -p "$(dirname "$path")"
                      printf '{"schema":"fkst.test.report.v1","summary":{"failed":%s},"tests":[]}\n' "$failed" > "$path"
                    }

                    command="${1:-}"
                    shift || true
                    case "$command" in
                      manifest) exit 10 ;;
                      conformance) exit 0 ;;
                      --self-test)
                        while [ "$#" -gt 0 ]; do
                          if [ "$1" = "--coverage" ]; then
                            shift
                            mkdir -p "$1"
                            printf '{}\n' > "$1/coverage.json"
                          fi
                          shift
                        done
                        exit 0
                        ;;
                      test)
                        report="" coverage="" project_root=""
                        while [ "$#" -gt 0 ]; do
                          case "$1" in
                            --report-json) shift; report="$1" ;;
                            --coverage) shift; coverage="$1" ;;
                            --project-root) shift; project_root="$1" ;;
                          esac
                          shift
                        done
                        case "$project_root" in
                          *fkst-sdk-probe*)
                            [ -z "$report" ] || write_report "$report" 0
                            exit 0
                            ;;
                        esac
                        package=${project_root##*/}
                        if [ -n "${FKST_TEST_ENGINE_LOG:-}" ]; then
                          printf '%s\n' "$package" >> "$FKST_TEST_ENGINE_LOG"
                        fi
                        if [ "$package" = "${FKST_TEST_ENGINE_FAIL_PACKAGE:-}" ]; then
                          write_report "$report" 1
                          exit 1
                        fi
                        case "${FKST_TEST_ENGINE_RESULT:-pass}" in
                          semantic-fail)
                            write_report "$report" 1
                            exit 1
                            ;;
                          infrastructure-fail)
                            printf '%s\n' 'engine dependency unavailable' >&2
                            exit 2
                            ;;
                          pass)
                            write_report "$report" 0
                            mkdir -p "$coverage"
                            printf '{}\n' > "$coverage/coverage.json"
                            exit 0
                            ;;
                        esac
                        ;;
                    esac
                    exit 0
                    """
                ),
                encoding="utf-8",
            )
            self.engine.chmod(self.engine.stat().st_mode | stat.S_IXUSR)
            self._init_repo(extra_packages)
        except BaseException:
            _robust_rmtree(self.tmp)
            raise

    def close(self) -> None:
        _robust_rmtree(self.tmp)

    def _git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", *args],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr + result.stdout)
        return result.stdout

    def _write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def _init_repo(self, extra_packages: tuple[str, ...]) -> None:
        self._git("init")
        # Deterministic fixture hygiene: forbid git's background auto-maintenance
        # so the repo has no detached gc/maintenance process that could write
        # .git after a foreground git returns. _robust_rmtree is the guarantee
        # against the teardown race; this just removes the most plausible writer.
        self._git("config", "gc.auto", "0")
        self._git("config", "maintenance.auto", "false")
        self._git("config", "user.email", "test@example.com")
        self._git("config", "user.name", "Test Runner")
        self._git("checkout", "-b", "dev")
        self._write("packages/consensus/core.lua", "return {}\n")
        self._write("packages/github-devloop/core.lua", "return {}\n")
        self._write("packages/frontend-devloop/core.lua", "return {}\n")
        self._write(
            "packages/consensus/fkst.toml",
            'kind = "package"\nname = "consensus"\n\n[lib_deps]\n'
            'libraries = ["consensus"]\n',
        )
        self._write(
            "packages/github-devloop/fkst.toml",
            'kind = "package.composed"\nname = "github-devloop"\n\n[lib_deps]\n'
            'libraries = ["devloop"]\n',
        )
        self._write(
            "packages/frontend-devloop/fkst.toml",
            'kind = "package.composed"\nname = "frontend-devloop"\n\n'
            '[lib_deps]\nlibraries = []\n\n[event_deps]\n'
            'packages = ["github-devloop"]\n',
        )
        for package in extra_packages:
            self._write(f"packages/{package}/core.lua", "return {}\n")
            self._write(
                f"packages/{package}/fkst.toml",
                f'kind = "package"\nname = "{package}"\n',
            )
        self._write(
            "libraries/workflow/fkst.toml",
            'kind = "library"\nname = "workflow"\n\n[lib_deps]\n'
            'libraries = ["contract"]\n',
        )
        self._write(
            "libraries/devloop/fkst.toml",
            'kind = "library"\nname = "devloop"\n\n[lib_deps]\n'
            'libraries = ["workflow"]\n',
        )
        self._write(
            "libraries/consensus/fkst.toml",
            'kind = "library"\nname = "consensus"\n\n[lib_deps]\n'
            'libraries = ["workflow"]\n',
        )
        self._write("scripts/helper.sh", "#!/bin/sh\n")
        self._write("README.md", "fixture\n")
        self._git("add", ".")
        self._git("commit", "-m", "initial")
        self._git("checkout", "-b", "integration")
        self._write("libraries/devloop/config.lua", "return {integration = true}\n")
        self._git("add", ".")
        self._git("commit", "-m", "integration ahead")
        self._git("checkout", "-b", "feature")

    def run(
        self,
        with_branch_env: bool = True,
        runner_exit: int = 0,
        runner_result: str | None = "PASS:NONE",
        runner_stdout: str | None = None,
        use_run_sh: bool = False,
        engine_fail_package: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.pop("FKST_LOCAL_ITERATION_RESULT_FILE", None)
        # Scope derives from the worktree's own uncommitted edits, so these env
        # vars must NOT be required; spawned implement/fix codex environments do
        # not carry them. Drop them to assert env-independence (with_branch_env=False).
        env.pop("FKST_DEVLOOP_UPSTREAM_BRANCH", None)
        env.pop("FKST_DEVLOOP_INTEGRATION_BRANCH", None)
        if with_branch_env:
            env["FKST_DEVLOOP_UPSTREAM_BRANCH"] = "dev"
            env["FKST_DEVLOOP_INTEGRATION_BRANCH"] = "integration"
        env["FKST_TEST_AFFECTED_RUNNER"] = str(self.runner)
        env["FKST_TEST_AFFECTED_LOG"] = str(self.log)
        env["FKST_TEST_CHECK_LOG"] = str(self.check_log)
        env["FKST_TEST_ENGINE_LOG"] = str(self.engine_log)
        env["FKST_TEST_REPO_ROOT"] = str(self.root)
        env["FKST_TEST_AFFECTED_RUNNER_EXIT"] = str(runner_exit)
        env["BIN"] = str(self.engine)
        env["FKST_NO_AUTOBUILD"] = "1"
        if use_run_sh:
            env["FKST_TEST_AFFECTED_USE_RUN_SH"] = "1"
        else:
            env.pop("FKST_TEST_AFFECTED_USE_RUN_SH", None)
        if engine_fail_package is None:
            env.pop("FKST_TEST_ENGINE_FAIL_PACKAGE", None)
        else:
            env["FKST_TEST_ENGINE_FAIL_PACKAGE"] = engine_fail_package
        if runner_result is None:
            env.pop("FKST_TEST_AFFECTED_RUNNER_RESULT", None)
        else:
            env["FKST_TEST_AFFECTED_RUNNER_RESULT"] = runner_result
        if runner_stdout is None:
            env.pop("FKST_TEST_AFFECTED_RUNNER_STDOUT", None)
        else:
            env["FKST_TEST_AFFECTED_RUNNER_STDOUT"] = runner_stdout
        return subprocess.run(
            ["/bin/bash", "scripts/run.sh", "test-affected"],
            cwd=self.root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_test_process(
        self,
        shell_body: str,
        engine_result: str = "pass",
        result_file: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.pop("FKST_LOCAL_ITERATION_RESULT_FILE", None)
        env["BIN"] = str(self.engine)
        env["FKST_NO_AUTOBUILD"] = "1"
        env["FKST_TEST_ENGINE_RESULT"] = engine_result
        env["FKST_TEST_CHECK_LOG"] = str(self.check_log)
        env["FKST_TEST_ENGINE_LOG"] = str(self.engine_log)
        if result_file is not None:
            env["FKST_LOCAL_ITERATION_RESULT_FILE"] = str(result_file)
        return subprocess.run(
            [
                "/bin/bash",
                "-c",
                ". scripts/run.sh\n" + shell_body,
            ],
            cwd=self.root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_default_test(self, engine_result: str) -> subprocess.CompletedProcess[str]:
        return self.run_test_process(
            "cmd_check() { return 0; }\nmain test github-devloop",
            engine_result,
        )

    def runner_args(self) -> list[str]:
        if not self.log.exists():
            return []
        return self.log.read_text(encoding="utf-8").splitlines()

    def check_calls(self) -> list[str]:
        if not self.check_log.exists():
            return []
        return self.check_log.read_text(encoding="utf-8").splitlines()

    def engine_packages(self) -> list[str]:
        if not self.engine_log.exists():
            return []
        return self.engine_log.read_text(encoding="utf-8").splitlines()


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
        packages = ("consensus", "frontend-devloop", "github-devloop") + tuple(
            f"extra-{index:02}" for index in range(1, 10)
        )
        h = TestAffectedHarness(packages[3:])
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
