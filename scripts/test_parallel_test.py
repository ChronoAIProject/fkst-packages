#!/usr/bin/env python3
"""Behavior tests for scripts/test_parallel.sh — the bounded parallel executor that
backs scripts/run.sh test/check.

These exercise the gate's OWN failure-propagation and ordering contract, which a green
full run never samples (a full run only walks the all-pass path). Without this, a future
edit that neutered `return "$fails"` or the rc-missing fail-closed fallback would keep CI
green while silently deadening the parallel gate."""
import json
import shlex
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
TEST_PARALLEL = REPO_ROOT / "scripts" / "test_parallel.sh"
RUN_SH = REPO_ROOT / "scripts" / "run.sh"


def _run(snippet: str) -> subprocess.CompletedProcess:
    """Source test_parallel.sh and run a bash snippet; return the completed process."""
    script = f'set -uo pipefail\n. "{TEST_PARALLEL}"\n{snippet}\n'
    return subprocess.run(
        ["/bin/bash", "-c", script],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )


def _run_run_sh(snippet: str) -> subprocess.CompletedProcess:
    """Source run.sh and run a bash snippet against its production functions."""
    script = f'set -uo pipefail\n. "{RUN_SH}"\n{snippet}\n'
    return subprocess.run(
        ["/bin/bash", "-c", script],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )


class DetectPoolSizeTest(unittest.TestCase):
    def test_returns_a_positive_integer(self) -> None:
        result = _run("detect_pool_size")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = result.stdout.strip()
        self.assertTrue(value.isdigit(), f"not an integer: {value!r}")
        self.assertGreaterEqual(int(value), 1)


class RunUnitsParallelTest(unittest.TestCase):
    def test_empty_unit_list_returns_zero(self) -> None:
        result = _run('run_units_parallel 4; echo "rc=$?"')
        self.assertIn("rc=0", result.stdout)

    def test_all_pass_returns_zero_failures(self) -> None:
        result = _run("run_units_parallel 3 'echo a' 'echo b' 'echo c'; echo \"rc=$?\"")
        self.assertIn("rc=0", result.stdout)

    def test_fail_count_via_recorded_nonzero_rc(self) -> None:
        # THE PRIMARY PRODUCTION PATH: a unit that returns nonzero WITHOUT exiting its
        # capturing subshell (an external process like `python3 -B check.py`, or
        # run_one_package which ends in `return`). The exit code is recorded by the
        # `printf '%s' "$?"` line, so this pins that line — a fail-open mutation of it
        # (record 0 instead of $?) makes every real failing check count as pass. 2 of 5
        # units fail via a recorded rc -> returned fail count must be exactly 2.
        result = _run(
            "run_units_parallel 3 'true' 'false' 'true' "
            "'python3 -c \"import sys; sys.exit(3)\"' 'true'; echo \"rc=$?\""
        )
        self.assertIn("rc=2", result.stdout)

    def test_fail_count_via_subshell_exit_missing_rc(self) -> None:
        # THE OTHER PATH: a unit whose eval'd command `exit`s terminates the capturing
        # subshell before the rc line, so no rc file is written -> fail-closed as a
        # failure. 2 of 5 units self-exit -> returned fail count must be exactly 2.
        result = _run(
            "run_units_parallel 3 'true' 'exit 1' 'true' 'exit 2' 'true'; echo \"rc=$?\""
        )
        self.assertIn("rc=2", result.stdout)

    def test_output_is_replayed_in_submission_order_regardless_of_duration(self) -> None:
        # U0 sleeps longest but is submitted first: output MUST still be U0..U4 in order,
        # proving deterministic submission-order replay (not completion order).
        result = _run(
            "run_units_parallel 5 "
            "'sleep 0.3; echo U0' 'echo U1' 'echo U2' 'sleep 0.1; echo U3' 'echo U4'"
        )
        lines = [ln for ln in result.stdout.splitlines() if ln.startswith("U")]
        self.assertEqual(lines, ["U0", "U1", "U2", "U3", "U4"])

    def test_waits_only_for_unit_jobs(self) -> None:
        # run.sh arms its deadline watchdog before entering the pool. That watchdog is
        # a sibling background job, not a verification unit, so the pool must not join
        # it. The fixture records if it had to self-expire before the pool returned;
        # after a scoped wait, the release file lets it exit immediately.
        result = _run(
            "fixture=$(mktemp -d); "
            "( touch \"$fixture/ready\"; "
            "for (( n=0; n<20; n++ )); do "
            "[ -e \"$fixture/release\" ] && exit 0; sleep 0.05; done; "
            "touch \"$fixture/expired\" ) >/dev/null 2>&1 & unrelated=$!; "
            "while [ ! -e \"$fixture/ready\" ]; do sleep 0.01; done; "
            "run_units_parallel 2 'echo unit'; rc=$?; "
            "[ ! -e \"$fixture/expired\" ] && echo ignored-unrelated-job; "
            "touch \"$fixture/release\"; wait \"$unrelated\"; rm -rf \"$fixture\"; "
            "echo \"rc=$rc\""
        )
        self.assertIn("ignored-unrelated-job", result.stdout)
        self.assertIn("rc=0", result.stdout)

    def test_work_dir_setup_failure_fails_closed(self) -> None:
        # If run_units_parallel cannot create its work directory (mktemp fails), it must
        # FAIL CLOSED — return nonzero with a diagnostic — never silently route unit
        # output to `/$i.out` (which on a writable-/ host, e.g. CI-as-root, would truncate
        # files at / and can return a false-green). Force mktemp to fail via a bad TMPDIR.
        result = _run(
            'TMPDIR=/no/such/dir/xyz run_units_parallel 2 '
            "'echo passA' 'echo passB'; echo \"rc=$?\""
        )
        self.assertNotIn("rc=0", result.stdout)
        self.assertIn("could not create its work directory", result.stderr + result.stdout)

    def test_unit_whose_subshell_exits_before_recording_rc_fails_closed(self) -> None:
        # A unit whose eval'd command `exit`s terminates the capturing subshell BEFORE
        # the `printf "$?" > rc` line runs, so no rc file is written. That abnormal
        # termination must fail-closed: the missing rc is counted as a failure, never a
        # silent pass. Here unit 1 self-exits; units 0 and 2 pass -> exactly 1 failure.
        result = _run(
            "run_units_parallel 2 'true' 'exit 0' 'true'; echo \"rc=$?\""
        )
        self.assertIn("rc=1", result.stdout)


class RunOnePackageTimingTest(unittest.TestCase):
    EXPECTED_KEYS = {
        "schema",
        "unit",
        "composed",
        "started_at_unix_ns",
        "ended_at_unix_ns",
        "elapsed_ms",
        "exit_status",
    }

    @staticmethod
    def _fixture_setup(root: Path) -> str:
        quoted_root = shlex.quote(str(root))
        return f"""
fixture_root={quoted_root}
report_dir="$fixture_root/reports"
coverage_report_dir="$fixture_root/coverage"
roots_parent="$fixture_root/roots"
flat_pkg="$fixture_root/flat"
composed_pkg="$fixture_root/composed"
mkdir -p "$report_dir" "$coverage_report_dir" "$roots_parent" \
  "$flat_pkg" "$composed_pkg/tests"
: >"$composed_pkg/tests/run_graph_fixture_test.lua"
BIN=fake-bin
verbose=0
FAKE_CONFORMANCE_RESULT=0
FAKE_MAIN_RESULT=0
FAKE_GRAPH_RESULT=0
timing_events="$fixture_root/timing-events"
run_quiet_pass() {{
  printf 'conformance\n' >>"$timing_events"
  return "$FAKE_CONFORMANCE_RESULT"
}}
run_quiet_keep() {{
  local report_file="" coverage_dir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report-json) report_file="$2"; shift 2 ;;
      --coverage) coverage_dir="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$coverage_dir"
  printf '{{}}\n' >"$report_file"
  printf '{{}}\n' >"$coverage_dir/coverage.json"
  case "$report_file" in
    *.graph.json)
      printf 'graph\n' >>"$timing_events"
      return "$FAKE_GRAPH_RESULT"
      ;;
    *)
      printf 'main\n' >>"$timing_events"
      return "$FAKE_MAIN_RESULT"
      ;;
  esac
}}
load_composed_test_roots() {{
  test_project_root="$pkg"
  test_pkg_args=(--package-root "$pkg")
  return 0
}}
install_test_clock() {{
  clock_values="$fixture_root/clock-values"
  printf '%s\n' "$@" >"$clock_values"
  test_timing_clock() {{
    local value next="$clock_values.next"
    IFS= read -r value <"$clock_values" || return 1
    tail -n +2 "$clock_values" >"$next" || return 1
    mv "$next" "$clock_values" || return 1
    if [ "${{ASSERT_UNIT_ROOTS_CLEAN_AT_FINAL_CLOCK:-0}}" = 1 ] \
        && [ ! -s "$clock_values" ]; then
      if [ -e "${{FKST_RUNTIME_ROOT:-}}" ] || [ -e "${{FKST_DURABLE_ROOT:-}}" ]; then
        printf 'cleanup-pending\n' >>"$timing_events"
      else
        printf 'cleanup-complete\n' >>"$timing_events"
      fi
    fi
    printf 'clock\n' >>"$timing_events"
    printf '%s\n' "$value"
  }}
}}
"""

    @classmethod
    def _read_record(cls, root: Path, name: str) -> dict:
        path = root / "reports" / "timing" / f"{name}.timing.json"
        record = json.loads(path.read_text())
        cls._assert_record_shape(record)
        return record

    @classmethod
    def _assert_record_shape(cls, record: dict) -> None:
        if set(record) != cls.EXPECTED_KEYS:
            raise AssertionError(f"unexpected record keys: {set(record)!r}")
        if record["schema"] != "fkst.test.unit_timing.v1":
            raise AssertionError(f"unexpected schema: {record['schema']!r}")
        if not isinstance(record["unit"], str):
            raise AssertionError("unit must be a string")
        if not isinstance(record["composed"], bool):
            raise AssertionError("composed must be a boolean")
        for key in ("started_at_unix_ns", "ended_at_unix_ns", "exit_status"):
            if not isinstance(record[key], int) or isinstance(record[key], bool):
                raise AssertionError(f"{key} must be an integer")
        if not isinstance(record["elapsed_ms"], (int, float)) or isinstance(
            record["elapsed_ms"], bool
        ):
            raise AssertionError("elapsed_ms must be numeric")

    def test_real_clock_adapter_uses_one_process_for_both_nanosecond_clocks(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            calls = Path(raw_root) / "python-calls"
            snippet = f"""
real_python3="$(command -v python3)"
python_calls={shlex.quote(str(calls))}
python3() {{
  printf 'call\n' >>"$python_calls"
  command "$real_python3" "$@"
}}
test_timing_clock
"""
            before_epoch_ns = time.time_ns()
            before_monotonic_ns = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
            result = _run(snippet)
            after_monotonic_ns = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
            after_epoch_ns = time.time_ns()

            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(calls.read_text().splitlines(), ["call"])
            fields = result.stdout.split()
            self.assertEqual(len(fields), 2, result.stdout)
            epoch_ns, monotonic_ns = map(int, fields)
            epoch_lower, epoch_upper = sorted((before_epoch_ns, after_epoch_ns))
            self.assertGreaterEqual(epoch_ns, epoch_lower)
            self.assertLessEqual(epoch_ns, epoch_upper)
            self.assertGreaterEqual(monotonic_ns, before_monotonic_ns)
            self.assertLessEqual(monotonic_ns, after_monotonic_ns)

    def test_final_clock_is_sampled_after_unit_roots_are_removed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            snippet = self._fixture_setup(root) + """
install_test_clock \
  '1700000000000000000 1000000000' '1700000000100000000 1150000000'
ASSERT_UNIT_ROOTS_CLEAN_AT_FINAL_CLOCK=1
run_one_package cleanup-order "$flat_pkg" 0 "$report_dir" \
  "$coverage_report_dir" "$roots_parent" fake-filter
printf 'rc=%s\n' "$?"
"""
            result = _run(snippet)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("rc=0", result.stdout)
            self.assertEqual(
                (root / "timing-events").read_text().splitlines(),
                ["clock", "conformance", "main", "cleanup-complete", "clock"],
            )
            record = self._read_record(root, "cleanup-order")
            self.assertEqual(record["ended_at_unix_ns"], 1700000000100000000)
            self.assertEqual(record["elapsed_ms"], 150.0)

    def test_exact_timings_and_artifact_set_for_mixed_units(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            snippet = self._fixture_setup(root) + """
install_test_clock \
  '1700000000000000000 1000000000' '1700000000100000000 1150000000' \
  '1700000000200000000 2000000000' '1700000000320000000 2210000000'
run_one_package flat "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
flat_rc=$?
run_one_package composed "$composed_pkg" 1 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
composed_rc=$?
printf 'flat_rc=%s composed_rc=%s\n' "$flat_rc" "$composed_rc"
"""
            result = _run(snippet)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("flat_rc=0 composed_rc=0", result.stdout)
            self.assertEqual(
                (root / "timing-events").read_text().splitlines(),
                [
                    "clock",
                    "conformance",
                    "main",
                    "clock",
                    "clock",
                    "main",
                    "graph",
                    "clock",
                ],
            )

            timing_dir = root / "reports" / "timing"
            self.assertEqual(
                {path.name for path in timing_dir.glob("*.json")},
                {
                    "flat.timing.json",
                    "composed.timing.json",
                },
            )
            flat = self._read_record(root, "flat")
            self.assertEqual(flat["unit"], "flat")
            self.assertFalse(flat["composed"])
            self.assertEqual(flat["started_at_unix_ns"], 1700000000000000000)
            self.assertEqual(flat["ended_at_unix_ns"], 1700000000100000000)
            self.assertEqual(flat["elapsed_ms"], 150.0)
            self.assertEqual(flat["exit_status"], 0)

            composed = self._read_record(root, "composed")
            self.assertEqual(composed["unit"], "composed")
            self.assertTrue(composed["composed"])
            self.assertEqual(composed["started_at_unix_ns"], 1700000000200000000)
            self.assertEqual(composed["ended_at_unix_ns"], 1700000000320000000)
            self.assertEqual(composed["elapsed_ms"], 210.0)
            self.assertEqual(composed["exit_status"], 0)

    def test_failure_records_pin_normalized_exit_status(self) -> None:
        cases = [
            (
                "conformance-failure",
                "flat_pkg",
                0,
                "FAKE_CONFORMANCE_RESULT=7",
                [
                    "1700000001000000000 1000000000",
                    "1700000001050000000 1050000000",
                ],
                50.0,
            ),
            (
                "main-failure",
                "flat_pkg",
                0,
                "FAKE_MAIN_RESULT=9",
                [
                    "1700000002000000000 2000000000",
                    "1700000002090000000 2090000000",
                ],
                90.0,
            ),
            (
                "graph-failure",
                "composed_pkg",
                1,
                "FAKE_GRAPH_RESULT=6",
                [
                    "1700000003000000000 3000000000",
                    "1700000003100000000 3100000000",
                ],
                100.0,
            ),
        ]
        for name, pkg_var, composed, control, clock, expected_elapsed in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw_root:
                root = Path(raw_root)
                values = " ".join(shlex.quote(value) for value in clock)
                snippet = self._fixture_setup(root) + f"""
install_test_clock {values}
{control}
run_one_package {name} "${pkg_var}" {composed} "$report_dir" \
  "$coverage_report_dir" "$roots_parent" fake-filter
printf 'rc=%s\n' "$?"
"""
                result = _run(snippet)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertIn("rc=1", result.stdout)
                record = self._read_record(root, name)
                self.assertEqual(record["exit_status"], 1)
                self.assertEqual(record["elapsed_ms"], expected_elapsed)

    def test_early_setup_failures_write_normalized_records(self) -> None:
        cases = [
            ("runtime-setup", "runtime", 4000000000, 4050000000),
            ("durable-setup", "durable", 5000000000, 5050000000),
            ("coverage-setup", "coverage", 6000000000, 6060000000),
        ]
        for name, failure, start_ns, end_ns in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw_root:
                root = Path(raw_root)
                snippet = self._fixture_setup(root) + f"""
install_test_clock \
  '1700000010000000000 {start_ns}' '1700000010060000000 {end_ns}'
real_mktemp="$(command -v mktemp)"
SETUP_FAILURE={failure}
mktemp() {{
  case "$SETUP_FAILURE:$*" in
    runtime:*'/rt.XXXXXX') return 1 ;;
    durable:*'/durable.XXXXXX') return 1 ;;
  esac
  command "$real_mktemp" "$@"
}}
if [ "$SETUP_FAILURE" = coverage ]; then
  coverage_report_dir="$fixture_root/coverage-blocker"
  printf 'not a directory\n' >"$coverage_report_dir"
fi
run_one_package {name} "$flat_pkg" 0 "$report_dir" \
  "$coverage_report_dir" "$roots_parent" fake-filter
printf 'rc=%s\n' "$?"
"""
                result = _run(snippet)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                self.assertIn("rc=1", result.stdout)
                record = self._read_record(root, name)
                self.assertEqual(record["exit_status"], 1)
                self.assertEqual(
                    record["elapsed_ms"], (end_ns - start_ns) / 1_000_000
                )

    def test_timing_write_failure_does_not_change_unit_exit_status(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            snippet = self._fixture_setup(root) + """
install_test_clock \
  '1700000020000000000 7000000000' '1700000020100000000 7100000000' \
  '1700000030000000000 8000000000' '1700000030100000000 8100000000'
printf 'not a directory\n' >"$report_dir/timing"
FAKE_MAIN_RESULT=0
run_one_package passing "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
passing_rc=$?
FAKE_MAIN_RESULT=9
run_one_package failing "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
failing_rc=$?
printf 'passing_rc=%s failing_rc=%s\n' "$passing_rc" "$failing_rc"
"""
            result = _run(snippet)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("passing_rc=0 failing_rc=1", result.stdout)
            self.assertGreaterEqual(
                (result.stderr + result.stdout).count(
                    "warning: could not create timing report directory"
                ),
                2,
            )

    def test_clock_capture_failure_warns_without_changing_verdict(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            snippet = self._fixture_setup(root) + """
test_timing_clock() { return 1; }
run_one_package clock-pass "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
passing_rc=$?
FAKE_MAIN_RESULT=8
run_one_package clock-fail "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
failing_rc=$?
printf 'passing_rc=%s failing_rc=%s\n' "$passing_rc" "$failing_rc"
"""
            result = _run(snippet)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("passing_rc=0 failing_rc=1", result.stdout)
            combined = result.stderr + result.stdout
            self.assertIn(
                "warning: could not capture timing clock for package clock-pass", combined
            )
            self.assertIn(
                "warning: could not capture timing clock for package clock-fail", combined
            )
            self.assertEqual(list((root / "reports" / "timing").glob("*.json")), [])

    def test_mid_write_failure_leaves_no_partial_final_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            snippet = self._fixture_setup(root) + """
install_test_clock \
  '1700000040000000000 9000000000' '1700000040100000000 9100000000' \
  '1700000050000000000 10000000000' '1700000050100000000 10100000000'
real_python3="$(command -v python3)"
python3() {
  if [ "$#" -gt 2 ]; then
    cat >/dev/null
    command "$real_python3" -B - "$3" <<'PY'
import errno
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write('{"schema": ')
    handle.flush()
    raise OSError(errno.ENOSPC, "injected mid-write failure")
PY
    return $?
  fi
  command "$real_python3" "$@"
}
run_one_package write-pass "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
passing_rc=$?
FAKE_MAIN_RESULT=8
run_one_package write-fail "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
failing_rc=$?
printf 'passing_rc=%s failing_rc=%s\n' "$passing_rc" "$failing_rc"
"""
            result = _run(snippet)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("passing_rc=0 failing_rc=1", result.stdout)
            combined = result.stderr + result.stdout
            self.assertIn(
                "warning: could not write timing record", combined
            )
            timing_dir = root / "reports" / "timing"
            self.assertEqual(list(timing_dir.glob("*.timing.json")), [])
            self.assertEqual(list(timing_dir.glob("*.tmp.*")), [])

    def test_serializer_sigkill_cannot_publish_its_partial_temp_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            destination = root / "published"
            snippet = self._fixture_setup(root) + f"""
install_test_clock \
  '1700000050000000000 10000000000' '1700000050100000000 10100000000'
real_python3="$(command -v python3)"
python3() {{
  if [ "$#" -gt 2 ]; then
    cat >/dev/null
    command "$real_python3" -B - "$3" <<'PY'
import os
import signal
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write('{{"schema": ')
    handle.flush()
    os.kill(os.getppid(), signal.SIGKILL)
PY
    return $?
  fi
  command "$real_python3" "$@"
}}
unit_rc=0
( run_one_package crash "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
    "$roots_parent" fake-filter ) || unit_rc=$?
FKST_TEST_REPORT_DIR={shlex.quote(str(destination))}
export FKST_TEST_REPORT_DIR
finish_test_reports "$report_dir"
printf 'unit_rc=%s\n' "$unit_rc"
"""
            result = _run_run_sh(snippet)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertNotIn("unit_rc=0", result.stdout)
            self.assertEqual(list(destination.rglob("*.tmp.*")), [])
            self.assertEqual(list(destination.rglob("*.timing.json")), [])
            private_temps = list((root / "roots").glob("*.tmp.*"))
            self.assertEqual(len(private_temps), 1)
            self.assertEqual(private_temps[0].read_text(), '{"schema": ')

    def test_timing_records_do_not_match_the_semantic_report_glob(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            snippet = self._fixture_setup(root) + """
install_test_clock \
  '1700000060000000000 11000000000' '1700000060100000000 11100000000'
run_one_package flat "$flat_pkg" 0 "$report_dir" "$coverage_report_dir" \
  "$roots_parent" fake-filter
"""
            result = _run(snippet)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

            report_dir = root / "reports"
            self.assertEqual(
                sorted(path.name for path in report_dir.glob("*.json")),
                ["flat.json"],
            )
            self.assertEqual(
                sorted(path.name for path in (report_dir / "timing").glob("*.json")),
                ["flat.timing.json"],
            )


class FinishTestReportsTest(unittest.TestCase):
    def test_public_timing_contract_states_clock_boundary_and_intent(self) -> None:
        source = RUN_SH.read_text()
        comment, separator, _ = source.partition("finish_test_reports() {")
        self.assertTrue(separator)
        contract = " ".join(
            line.removeprefix("# ").strip()
            for line in comment.splitlines()[-20:]
            if line.startswith("# ")
        )
        self.assertIn("end clock adapter's own invocation latency", contract)
        self.assertIn("interpreter startup", contract)
        self.assertIn("about 20 ms per read", contract)
        self.assertIn("critical-path analysis", contract)

    def test_recursively_publishes_reports_and_nested_timing_records(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "source"
            destination = root / "destination"
            snippet = f"""
source_dir={shlex.quote(str(source))}
FKST_TEST_REPORT_DIR={shlex.quote(str(destination))}
export FKST_TEST_REPORT_DIR
mkdir -p "$source_dir/timing"
printf '{{"schema":"fkst.test.report.v1"}}\n' >"$source_dir/unit.json"
printf '{{"schema":"fkst.test.unit_timing.v1"}}\n' \
  >"$source_dir/timing/unit.timing.json"
finish_test_reports "$source_dir"
"""
            result = _run_run_sh(snippet)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                json.loads((destination / "unit.json").read_text())["schema"],
                "fkst.test.report.v1",
            )
            self.assertEqual(
                json.loads(
                    (destination / "timing" / "unit.timing.json").read_text()
                )["schema"],
                "fkst.test.unit_timing.v1",
            )
            self.assertFalse(source.exists())


class FailCodeSurfaceTest(unittest.TestCase):
    """The fold must say WHICH nonzero codes it saw, not only how many units failed.

    A caller cannot classify a failure it cannot see: a unit that typed itself (the conformance
    checker's violations code) and a unit that merely died are both `fails=1`, so without this the
    caller can only emit UNKNOWN — which the implement loop redrives forever. Units run as external
    commands, so their status reaches the wrapper; a bare `exit` would leave the wrapper before its
    rc is recorded (see test_fail_count_via_subshell_exit_missing_rc).
    """

    def test_reports_the_distinct_nonzero_codes(self) -> None:
        result = _run(
            "run_units_parallel 3 '( exit 10 )' 'true' '( exit 10 )'; "
            'echo "rc=$?"; echo "codes=$RUN_UNITS_FAIL_CODES"'
        )
        self.assertIn("rc=2", result.stdout, result.stdout + result.stderr)
        self.assertIn("codes=10", result.stdout, result.stdout + result.stderr)

    def test_mixed_codes_are_all_reported(self) -> None:
        result = _run(
            "run_units_parallel 3 '( exit 10 )' '( exit 1 )'; "
            'echo "codes=$RUN_UNITS_FAIL_CODES"'
        )
        codes = [ln for ln in result.stdout.splitlines() if ln.startswith("codes=")]
        self.assertEqual(len(codes), 1, result.stdout + result.stderr)
        self.assertEqual(sorted(codes[0][len("codes="):].split()), ["1", "10"])

    def test_all_pass_reports_no_codes(self) -> None:
        result = _run(
            "run_units_parallel 2 'true' 'true'; " 'echo "codes=[$RUN_UNITS_FAIL_CODES]"'
        )
        self.assertIn("codes=[]", result.stdout, result.stdout + result.stderr)


class CheckVerdictMappingTest(unittest.TestCase):
    """cmd_check must turn the typed violations code into FAIL:SEMANTIC, not UNKNOWN.

    This closes the last link of the chain: check_repo.py returns the typed code (asserted in
    scripts/check_repo_gh_egress_test.py), run_units_parallel surfaces it (asserted above), and the
    caller must map it. Without the mapping the verdict falls back to UNKNOWN, which the implement
    loop redrives forever instead of reporting a defect the implementation can act on.
    """

    RUN_SH = REPO_ROOT / "scripts" / "run.sh"

    def _verdict_for(self, codes: str) -> str:
        # Replace only the executor, so the real cmd_check body decides the verdict.
        snippet = (
            'run_units_parallel() { RUN_UNITS_FAIL_CODES="%s"; '
            '[ -z "$RUN_UNITS_FAIL_CODES" ] || return 1; }\n'
            "competence_gate_base_ref() { echo HEAD; }\n"
            "detect_pool_size() { echo 1; }\n"
            'resolve_bin() { :; }\n'
            "cmd_check >/dev/null 2>&1 || true\n"
            'printf %%s "$LOCAL_ITERATION_RESULT_VERDICT:$LOCAL_ITERATION_RESULT_FAULT_CLASS"\n'
        ) % codes
        script = (
            "set -uo pipefail\n"
            'FKST_RUN_SH_SOURCE_ONLY=1\n'
            f'. "{self.RUN_SH}" 2>/dev/null || true\n'
            + snippet
        )
        return subprocess.run(
            ["/bin/bash", "-c", script], capture_output=True, text=True, cwd=REPO_ROOT
        ).stdout.strip()

    def test_typed_violations_code_maps_to_semantic(self) -> None:
        self.assertEqual(self._verdict_for("10"), "FAIL:SEMANTIC")

    def test_typed_configuration_code_maps_to_configuration(self) -> None:
        self.assertEqual(self._verdict_for("11"), "FAIL:CONFIGURATION")

    def test_bare_nonzero_leaves_the_verdict_unset(self) -> None:
        # Attribution is genuinely indeterminate, so cmd_check must set NOTHING and let the exit
        # trap record the honest UNKNOWN. Asserting the empty verdict (rather than merely "not
        # SEMANTIC") is what makes this fail if cmd_check ever starts guessing.
        self.assertEqual(self._verdict_for("1"), ":")

    def test_mixed_codes_leave_the_verdict_unset(self) -> None:
        # One unit typed itself and another did not: the run as a whole is not attributable.
        self.assertEqual(self._verdict_for("10 1"), ":")


if __name__ == "__main__":
    unittest.main()
