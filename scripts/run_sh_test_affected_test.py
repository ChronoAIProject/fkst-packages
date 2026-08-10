#!/usr/bin/env python3
"""Execution tests for scripts/run.sh test-affected."""

from __future__ import annotations

import json
import os
import shlex
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
    def __init__(self) -> None:
        # mkdtemp (not TemporaryDirectory) so cleanup has a single explicit owner
        # via _robust_rmtree. Construction happens before the caller's
        # try/finally: h.close(), so clean up here if any construction step fails.
        self.tmp = tempfile.mkdtemp()
        try:
            self.root = Path(self.tmp) / "repo"
            self.scripts = self.root / "scripts"
            self.log = Path(self.tmp) / "runner.log"
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
                "composed_test_graph_roots.sh",
                "test_parallel.sh",
                "test_deadline.sh",
                "run_department.sh",
                "test_selection.py",
                "check_repo_intake_routing.py",
                "intake_policy_slots.json",
            ):
                shutil.copy2(REPO_ROOT / "scripts" / name, self.scripts / name)
            test_affected = REPO_ROOT / "scripts" / "test_affected.sh"
            if test_affected.exists():
                shutil.copy2(test_affected, self.scripts / "test_affected.sh")
            local_iteration_result = REPO_ROOT / "scripts" / "local_iteration_result.sh"
            if local_iteration_result.exists():
                shutil.copy2(local_iteration_result, self.scripts / "local_iteration_result.sh")
            self.runner.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$FKST_TEST_AFFECTED_LOG\"\n"
                "result=${FKST_TEST_AFFECTED_RUNNER_RESULT:-}\n"
                "if [ -n \"$result\" ]; then\n"
                "  marker=FKST_LOCAL_ITERATION_RESULT:v2:$result\n"
                "  if [ -n \"${FKST_LOCAL_ITERATION_RESULT_FILE:-}\" ]; then\n"
                "    printf '%s\\n' \"$marker\" > \"$FKST_LOCAL_ITERATION_RESULT_FILE\"\n"
                "  else\n"
                "    printf '%s\\n' \"$marker\" >&2\n"
                "  fi\n"
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
                      deps)
                        if [ "${FKST_TEST_DEPS_EXIT:-0}" -ne 0 ]; then
                          exit "$FKST_TEST_DEPS_EXIT"
                        fi
                        if [ -n "${FKST_TEST_DEPS_OUTPUT:-}" ]; then
                          printf '%s\n' "$FKST_TEST_DEPS_OUTPUT"
                        else
                          cat "$FKST_TEST_DEPS_JSON"
                        fi
                        exit 0
                        ;;
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
            self._init_repo()
            self.deps_json = Path(self.tmp) / "deps.json"
            self._write_dependency_json()
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

    def _init_repo(self) -> None:
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
        self._write("scripts/helper.sh", "#!/bin/sh\n")
        self._write("README.md", "fixture\n")
        self._git("add", ".")
        self._git("commit", "-m", "initial")
        self._git("checkout", "-b", "integration")
        self._write("libraries/devloop/config.lua", "return {integration = true}\n")
        self._git("add", ".")
        self._git("commit", "-m", "integration ahead")
        self._git("checkout", "-b", "feature")

    def _write_dependency_json(self) -> None:
        payload = {
            "ok": True,
            "workspace_root": str(self.root),
            "failures": [],
            "warnings": [],
            "units": [
                {
                    "name": "consensus-tests",
                    "kind": "package",
                    "root": str(self.root / "packages" / "consensus"),
                    "lib_deps": [],
                    "event_deps": [],
                },
                {
                    "name": "github-devloop",
                    "kind": "package",
                    "root": str(self.root / "packages" / "github-devloop"),
                    "lib_deps": ["devloop"],
                    "event_deps": [],
                },
                {
                    "name": "devloop",
                    "kind": "library",
                    "root": str(self.root / "libraries" / "devloop"),
                    "lib_deps": [],
                    "event_deps": [],
                },
            ],
            "lib_edges": [{"from": "github-devloop", "to": "devloop"}],
            "event_edges": [],
        }
        self.deps_json.write_text(json.dumps(payload), encoding="utf-8")

    def run(
        self,
        with_branch_env: bool = True,
        runner_exit: int = 0,
        runner_result: str | None = "PASS:NONE",
        deps_exit: int = 0,
        deps_output: str | None = None,
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
        env["FKST_TEST_AFFECTED_RUNNER_EXIT"] = str(runner_exit)
        env["BIN"] = str(self.engine)
        env["FKST_NO_AUTOBUILD"] = "1"
        env["FKST_TEST_DEPS_JSON"] = str(self.deps_json)
        env["FKST_TEST_DEPS_EXIT"] = str(deps_exit)
        if deps_output is None:
            env.pop("FKST_TEST_DEPS_OUTPUT", None)
        else:
            env["FKST_TEST_DEPS_OUTPUT"] = deps_output
        if runner_result is None:
            env.pop("FKST_TEST_AFFECTED_RUNNER_RESULT", None)
        else:
            env["FKST_TEST_AFFECTED_RUNNER_RESULT"] = runner_result
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


class RunShTestAffectedTest(unittest.TestCase):
    def test_scopes_to_uncommitted_changed_package(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test github-devloop"])
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
            self.assertEqual(h.runner_args(), ["test github-devloop"])
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
            self.assertEqual(h.runner_args(), ["test github-devloop"])
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

    def test_default_test_runs_target_union(self) -> None:
        cases = (
            ("consensus", ("consensus",)),
            ("consensus github-devloop", ("consensus", "github-devloop")),
            ("-v github-devloop", ("github-devloop",)),
        )
        for targets, expected_packages in cases:
            with self.subTest(targets=targets):
                h = TestAffectedHarness()
                try:
                    result = h.run_test_process(
                        "cmd_check() { printf '%s\\n' check >> \"$ROOT/check-count\"; return 0; }\n"
                        f"main test {targets}"
                    )

                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    self.assertEqual(
                        (h.root / "check-count").read_text(encoding="utf-8"),
                        "check\n",
                    )
                    self.assertEqual(result.stdout.count("=== self-test ==="), 1)
                    self.assertEqual(result.stdout.count("=== sdk-primitives ==="), 1)
                    for package in expected_packages:
                        self.assertIn(f"=== {package} ===", result.stdout)
                    self.assertIn(
                        f"OK: {len(expected_packages)} package(s)",
                        result.stdout,
                    )
                    if expected_packages == ("consensus",):
                        self.assertNotIn("=== github-devloop ===", result.stdout)
                finally:
                    h.close()

    def test_default_test_fails_when_any_target_is_unmatched(self) -> None:
        valid_targets = ("consensus", "github-devloop", "consensus", "github-devloop")
        for bogus_index in range(len(valid_targets) + 1):
            targets = list(valid_targets)
            targets.insert(bogus_index, "missing-package")
            with self.subTest(bogus_index=bogus_index, target_count=len(targets)):
                h = TestAffectedHarness()
                try:
                    result = h.run_test_process(
                        "cmd_check() { return 0; }\n"
                        f"main test {shlex.join(targets)}"
                    )

                    self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
                    self.assertEqual(
                        result_markers(result),
                        [result_marker("FAIL", "CONFIGURATION")],
                    )
                    self.assertIn(
                        "no packages matched for 'missing-package'",
                        result.stderr + result.stdout,
                    )
                    self.assertNotIn("=== self-test ===", result.stdout)
                    self.assertNotIn("=== sdk-primitives ===", result.stdout)
                    self.assertNotIn("=== github-devloop ===", result.stdout)
                    self.assertNotIn("test hermetic: FKST_RUNTIME_ROOT", result.stdout)
                    self.assertNotIn("narrowed local test", result.stdout)
                finally:
                    h.close()

    def test_default_test_cleanup_owns_only_invocation_created_roots(self) -> None:
        root_kinds = ("runtime", "durable", "pkgroots")
        for acquired_before_failure in range(len(root_kinds) + 1):
            with self.subTest(acquired_before_failure=acquired_before_failure):
                h = TestAffectedHarness()
                try:
                    inherited_roots = tuple(
                        Path(h.tmp) / f"inherited-{kind}" for kind in root_kinds
                    )
                    created_roots = tuple(
                        Path(h.tmp) / f"created-{kind}" for kind in root_kinds
                    )
                    acquired_log = Path(h.tmp) / "acquired-roots.log"
                    for root in inherited_roots:
                        root.mkdir()
                        (root / "sentinel").write_text("preserve\n", encoding="utf-8")

                    result = h.run_test_process(
                        "cmd_check() { return 0; }\n"
                        f"export TEST_HERMETIC_RUNTIME_ROOT={shlex.quote(str(inherited_roots[0]))}\n"
                        f"export TEST_HERMETIC_DURABLE_ROOT={shlex.quote(str(inherited_roots[1]))}\n"
                        f"export TEST_HERMETIC_PKG_ROOTS={shlex.quote(str(inherited_roots[2]))}\n"
                        f"CREATED_RUNTIME={shlex.quote(str(created_roots[0]))}\n"
                        f"CREATED_DURABLE={shlex.quote(str(created_roots[1]))}\n"
                        f"CREATED_PKGROOTS={shlex.quote(str(created_roots[2]))}\n"
                        f"ACQUIRED_LOG={shlex.quote(str(acquired_log))}\n"
                        f"FAIL_AFTER={acquired_before_failure}\n"
                        f"ROOT_COUNT={len(root_kinds)}\n"
                        "mktemp() {\n"
                        "  case \"$*\" in\n"
                        "    *fkst-test-rt.XXXXXX*) stage=0; root=$CREATED_RUNTIME ;;\n"
                        "    *fkst-test-durable.XXXXXX*) stage=1; root=$CREATED_DURABLE ;;\n"
                        "    *fkst-test-pkgroots.XXXXXX*) stage=2; root=$CREATED_PKGROOTS ;;\n"
                        "    *) command mktemp \"$@\"; return ;;\n"
                        "  esac\n"
                        "  if [ \"$FAIL_AFTER\" -lt \"$ROOT_COUNT\" ] && [ \"$stage\" -eq \"$FAIL_AFTER\" ]; then\n"
                        "    return 1\n"
                        "  fi\n"
                        "  mkdir -p \"$root\"\n"
                        "  printf '%s\\n' \"$stage\" >> \"$ACQUIRED_LOG\"\n"
                        "  printf '%s\\n' \"$root\"\n"
                        "}\n"
                        "main test github-devloop"
                    )

                    if acquired_before_failure == len(root_kinds):
                        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)
                    acquired = (
                        acquired_log.read_text(encoding="utf-8").splitlines()
                        if acquired_log.exists()
                        else []
                    )
                    self.assertEqual(
                        acquired,
                        [str(index) for index in range(acquired_before_failure)],
                    )
                    for root in inherited_roots:
                        self.assertTrue(
                            (root / "sentinel").is_file(),
                            f"inherited root deleted: {root}",
                        )
                    for root in created_roots[:acquired_before_failure]:
                        self.assertFalse(
                            root.exists(),
                            f"invocation-created root survived: {root}",
                        )
                finally:
                    h.close()

    def test_default_test_target_banner_names_skipped_aggregate_gates(self) -> None:
        h = TestAffectedHarness()
        try:
            result = h.run_test_process(
                "cmd_check() { return 0; }\nmain test github-devloop"
            )

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            output = result.stderr + result.stdout
            self.assertIn("not the CI gate", output)
            self.assertIn("composed conformance", output)
            self.assertIn("Lua coverage ratchet", output)
            self.assertIn("G5 test-file coverage", output)
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
            self.assertNotIn("narrowed local test: not the CI gate", result.stderr + result.stdout)
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

    def test_test_affected_preserves_aggregate_semantic_fault(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/consensus/core.lua", "return {changed = true}\n")
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(
                runner_exit=1,
                runner_result="FAIL:SEMANTIC",
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "SEMANTIC")],
            )
            self.assertEqual(h.runner_args(), ["test consensus github-devloop"])
        finally:
            h.close()

    def test_test_affected_preserves_aggregate_toolchain_fault(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/consensus/core.lua", "return {changed = true}\n")
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run(
                runner_exit=1,
                runner_result="FAIL:TOOLCHAIN",
            )

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "TOOLCHAIN")],
            )
        finally:
            h.close()

    def test_test_affected_rejects_deleted_target_before_existing_package_runs(self) -> None:
        h = TestAffectedHarness()
        try:
            h._git("rm", "-r", "packages/consensus")
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")
            h.runner.write_text(
                "#!/usr/bin/env bash\n"
                f". {shlex.quote(str(h.scripts / 'run.sh'))}\n"
                "cmd_check() { return 0; }\n"
                f"BIN={shlex.quote(str(h.engine))}\n"
                "export BIN FKST_NO_AUTOBUILD=1\n"
                "export FKST_TEST_ENGINE_RESULT=semantic-fail\n"
                "main \"$@\"\n",
                encoding="utf-8",
            )

            result = h.run()

            self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
            self.assertEqual(
                result_markers(result),
                [result_marker("FAIL", "CONFIGURATION")],
            )
            output = result.stderr + result.stdout
            self.assertIn("no packages matched for 'consensus'", output)
            self.assertNotIn("=== self-test ===", output)
            self.assertNotIn("=== sdk-primitives ===", output)
            self.assertNotIn("=== github-devloop ===", output)
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
            self.assertEqual(h.runner_args(), ["test github-devloop"])
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

    def test_runs_full_for_dogfood_operator_paths(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write(".claude/skills/dogfood-github-devloop/dogfood.sh", "#!/usr/bin/env bash\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test"])
        finally:
            h.close()

    def test_runs_changed_packages_through_one_gate_invocation(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/consensus/core.lua", "return {changed = true}\n")
            h._write("packages/github-devloop/core.lua", "return {changed = true}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test consensus github-devloop"])
        finally:
            h.close()

    def test_untracked_new_package_file_is_counted(self) -> None:
        h = TestAffectedHarness()
        try:
            h._write("packages/github-devloop/new_module.lua", "return {}\n")

            result = h.run()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(h.runner_args(), ["test github-devloop"])
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main()
