#!/usr/bin/env bash
# Bounded parallel execution helpers for the run.sh test/check orchestration.
#
# The full gate `scripts/run.sh test` is a COMPLETE, order-free AND-fold over
# mutually-independent verification units: ~40 repo-check python processes in
# cmd_check and one engine process per package in cmd_test. AND is commutative, so
# running the units concurrently changes only wall-clock, never which units run or
# their pass/fail set. These helpers own that concurrency (bounded to logical cores),
# a deterministic replay of each unit's output, and per-unit hermetic runtime/durable
# roots so parallel package runs never share engine state. Sourced into run.sh's shell
# so the units inherit its functions and (dynamic-scoped) locals.

# Parallel pool size = logical core count (a hardware fact read from the OS, not a
# magic constant). Falls back conservatively when the count cannot be read.
detect_pool_size() {
  local n=""
  n="$(sysctl -n hw.logicalcpu 2>/dev/null || true)"
  [ -n "$n" ] || n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  [ -n "$n" ] || n="$(nproc 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=4 ;; esac
  [ "$n" -ge 1 ] 2>/dev/null || n=4
  printf '%s\n' "$n"
}

# Run independent unit commands concurrently under a bounded worker pool, then replay
# each unit's captured output in submission order and AND-fold their exit codes. The
# verdict (count of failed units) is order-independent — parallelism changes only the
# wall-clock of independent work, never the pass/fail set. Units run as background
# subshells of the caller's shell, so they inherit every function and global defined
# there (no export or shell-out-to-self needed). Work-stealing throttle via `jobs -pr`
# keeps it bash-3.2 compatible (no `wait -n`).
# Args: <pool-size> <unit-command-string>...   Returns: count of failed units.
run_units_parallel() {
  local pool="$1"; shift
  local -a cmds=("$@")
  local -a unit_pids=()
  local n=${#cmds[@]}
  [ "$n" -gt 0 ] || return 0
  # Fail CLOSED on setup failure: run under `set +e` / left-of-|| where errexit is
  # suppressed, so an unchecked mktemp would leave $dir empty and route unit output to
  # `/$i.out` — silently truncating files at / on a writable-/ host (CI-as-root) and
  # potentially returning a false-green. An explicit check makes infra failure a failure.
  local dir
  if ! dir="$(mktemp -d "${TMPDIR:-/tmp}/fkst-units.XXXXXX")"; then
    echo "error: run_units_parallel could not create its work directory" >&2
    return 1
  fi
  # Distinct nonzero codes observed this run, so a caller can tell a typed failure (a checker
  # reporting violations) from a bare nonzero (attribution indeterminate). The RETURN value stays
  # the failure count, so existing callers are unaffected.
  RUN_UNITS_FAIL_CODES=""
  local i j fails=0 rc running
  for (( i=0; i<n; i++ )); do
    # Throttle: launch the next unit only once a worker slot frees (true work-stealing).
    while :; do
      running="$(jobs -pr | wc -l | tr -d ' ')"
      [ "${running:-0}" -lt "$pool" ] && break
      sleep 0.05
    done
    ( set +e; eval "${cmds[$i]}" >"$dir/$i.out" 2>&1; printf '%s' "$?" >"$dir/$i.rc" ) &
    unit_pids+=("$!")
  done
  local unit_pid
  for unit_pid in "${unit_pids[@]}"; do
    wait "$unit_pid" || true
  done
  for (( j=0; j<n; j++ )); do
    cat "$dir/$j.out" 2>/dev/null || true
    rc="$(cat "$dir/$j.rc" 2>/dev/null || printf '1')"
    if [ "$rc" != 0 ]; then
      fails=$(( fails + 1 ))
      if [ "$rc" = 10 ] && declare -F local_iteration_failure_identity_check >/dev/null; then
        local_iteration_failure_identity_check "${cmds[$j]}"
      fi
      case " $RUN_UNITS_FAIL_CODES " in
        *" $rc "*) ;;
        *) RUN_UNITS_FAIL_CODES="${RUN_UNITS_FAIL_CODES:+$RUN_UNITS_FAIL_CODES }$rc" ;;
      esac
    fi
  done
  rm -rf "$dir"
  return "$fails"
}

test_reports_establish_semantic_failure() {
  local report_dir="$1" expected_failures="$2"
  python3 -B - "$report_dir" "$expected_failures" "$LOCAL_ITERATION_FAILURE_IDENTITY_PREFIX" <<'PY'
import json
import sys
from pathlib import Path

report_dir = Path(sys.argv[1])
expected_failures = int(sys.argv[2])
semantic_failures = 0
identities = set()
try:
    for report_path in sorted(report_dir.glob("*.json")):
        with report_path.open(encoding="utf-8") as handle:
            report = json.load(handle)
        if report.get("schema") != "fkst.test.report.v1":
            raise ValueError("unexpected test report schema")
        summary = report.get("summary")
        if not isinstance(summary, dict):
            raise ValueError("missing test report summary")
        if int(summary.get("failed", 0)) > 0:
            semantic_failures += 1
        for test in report.get("tests", []):
            if not isinstance(test, dict) or test.get("status") != "fail":
                continue
            identity = {
                "kind": "test",
                "owner_namespace": test.get("owner_namespace"),
                "file": test.get("file"),
                "name": test.get("name"),
                "failure_kind": test.get("failure_kind"),
            }
            if not all(isinstance(value, str) and value for value in identity.values()):
                raise ValueError("failed test has no exact identity")
            identities.add(json.dumps(identity, sort_keys=True, separators=(",", ":")))
except (OSError, TypeError, ValueError):
    raise SystemExit(1)
established = semantic_failures > 0 and semantic_failures == expected_failures and bool(identities)
if established:
    for identity in sorted(identities):
        print(sys.argv[3] + identity)
raise SystemExit(0 if established else 1)
PY
}

test_timing_clock() {
  # Python is already a test-path dependency. These clocks are portable across the
  # supported macOS/Linux hosts and avoid incompatible `date` flags.
  python3 -B - <<'PY'
import time

print(f"{time.time_ns()} {time.clock_gettime_ns(time.CLOCK_MONOTONIC)}")
PY
}

capture_test_timing_clock() {
  local realtime_target="$1" monotonic_target="$2" value=""
  if ! value="$(test_timing_clock 2>/dev/null)" \
      || ! [[ "$value" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
    printf -v "$realtime_target" '%s' ""
    printf -v "$monotonic_target" '%s' ""
    return 1
  fi
  printf -v "$realtime_target" '%s' "${BASH_REMATCH[1]}"
  printf -v "$monotonic_target" '%s' "${BASH_REMATCH[2]}"
}

write_unit_timing() {
  local timing_file="$1" name="$2" is_pkg_composed="$3" scratch_dir="$4"
  local timing_tmp=""
  shift 4
  if ! timing_tmp="$(mktemp "$scratch_dir/unit-timing.tmp.XXXXXX" 2>/dev/null)"; then
    echo "warning: could not write timing record $timing_file" >&2
    return 0
  fi
  if python3 -B - "$timing_tmp" "$name" "$is_pkg_composed" "$@" 2>/dev/null <<'PY'
import json
import sys
from pathlib import Path


def integer(index):
    return int(sys.argv[index])


def elapsed_ms(start, end):
    elapsed_ns = end - start
    if elapsed_ns < 0:
        raise ValueError("monotonic clock moved backwards")
    return elapsed_ns / 1_000_000


timing_file = Path(sys.argv[1])
started_at_unix_ns = integer(4)
ended_at_unix_ns = integer(5)
started_at_monotonic_ns = integer(6)
ended_at_monotonic_ns = integer(7)

record = {
    "schema": "fkst.test.unit_timing.v1",
    "unit": sys.argv[2],
    "composed": sys.argv[3] == "1",
    "started_at_unix_ns": started_at_unix_ns,
    "ended_at_unix_ns": ended_at_unix_ns,
    "elapsed_ms": elapsed_ms(started_at_monotonic_ns, ended_at_monotonic_ns),
    "exit_status": integer(8),
}
with timing_file.open("w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  then
    if mv -f "$timing_tmp" "$timing_file" 2>/dev/null; then
      return 0
    fi
  fi
  rm -f "$timing_tmp"
  echo "warning: could not write timing record $timing_file" >&2
  return 0
}

finish_one_package_timing() {
  local report_dir="$1" name="$2" is_pkg_composed="$3"
  local started_at_unix_ns="$4" started_at_monotonic_ns="$5" result="$6"
  local timing_capture_failed="$7" roots_parent="$8"
  local timing_dir="$report_dir/timing"
  local ended_at_unix_ns="" ended_at_monotonic_ns=""
  capture_test_timing_clock ended_at_unix_ns ended_at_monotonic_ns \
    || timing_capture_failed=1
  # Timing is an observation channel, never a gate: a capture/write failure warns
  # but the caller always returns the package's already-established result.
  if [ "$timing_capture_failed" -ne 0 ]; then
    echo "warning: could not capture timing clock for package $name" >&2
    return 0
  fi
  if ! mkdir -p "$timing_dir"; then
    echo "warning: could not create timing report directory $timing_dir" >&2
    return 0
  fi
  write_unit_timing "$timing_dir/$name.timing.json" "$name" "$is_pkg_composed" \
    "$roots_parent" \
    "$started_at_unix_ns" "$ended_at_unix_ns" \
    "$started_at_monotonic_ns" "$ended_at_monotonic_ns" "$result" || true
  return 0
}

# Run one package's conformance + test(s) with its OWN ephemeral runtime/durable roots,
# so packages running in parallel never share engine runtime/durable state (the tests'
# real filesystem IO is FKST_RUNTIME_ROOT-relative). The collection dirs (report_dir,
# coverage_report_dir), the roots_parent, and the failure filter are EXPLICIT arguments
# (the contract is in the signature, not a comment); the per-package roots are created
# UNDER roots_parent, which cmd_test registers in its EXIT trap so they are swept even if
# a unit subshell is killed. `--report-json`/`--coverage` land in the shared $name-keyed
# collection dirs for the post-join ratchet/G5 fan-in. Mirrors the former serial loop
# body exactly; returns 0 on success, 1 on any failure. `verbose` and the run_quiet_*/
# load_composed_test_roots functions and BIN are legitimately module-ambient.
#
# CONTRACT: unit commands (this and the cmd_check checks) must always `return`, never
# `exit` — an `exit` terminates the pool's capturing subshell before it records the exit
# code, which run_units_parallel then fail-closes as a failure. run_one_package must be
# invoked only via run_units_parallel (its FKST_RUNTIME_ROOT export relies on the subshell).
# Emit package source directories ordered by DESCENDING test-file count, ties broken by
# name so the order is deterministic across runs and machines.
#
# Why order at all: run_units_parallel launches strictly in list order as slots free, so the
# list IS the dispatch order and whatever sits last starts last. A pool's makespan is bounded
# below by max(longest unit, total work / slots); when one unit is most of the span, its start
# delay is added to that floor and nothing downstream can recover it. Enumerating packages by
# directory glob ordered them alphabetically, which is uncorrelated with cost.
#
# What this does NOT change: which units run, or their verdicts. Each unit is an independent
# process with its own ephemeral roots and a $name-keyed report, so the pool result is a
# commutative AND-fold -- reordering moves launch times only.
#
# The key is a heuristic for cost, not cost. The engine's test report carries no per-test
# duration (fkst-substrate#371), so real per-unit cost is unknown before the run. Test-file
# count is used only to RANK, and it ranks the part that matters: the two costliest units are
# also the two largest by file count with a wide margin to the third. A wrong ranking further
# down costs at most what an unordered list already costs.
test_units_longest_first() {
  local root="$1" dir name count
  for dir in "$root"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    # Test the directory explicitly rather than letting find fail into 2>/dev/null: run.sh
    # runs under `set -euo pipefail`, so a find that exits nonzero on a package without a
    # tests/ directory aborts this function and the pool is handed an EMPTY unit list --
    # every package silently skipped, reported only as "no packages matched".
    if [ -d "$dir/tests" ]; then
      count="$(find "$dir/tests" -name '*_test.lua' -type f | wc -l | tr -d ' ')"
    else
      count=0
    fi
    printf '%s\t%s\t%s\n' "$count" "$name" "$dir"
  done | LC_ALL=C sort -k1,1nr -k2,2 | cut -f3-
}

run_one_package() {
  local name="$1" pkg="$2" is_pkg_composed="$3"
  local report_dir="$4" coverage_report_dir="$5" roots_parent="$6" test_failure_filter="$7"
  local rt dur report_file coverage_dir test_project_root result=0
  local started_at_unix_ns="" started_at_monotonic_ns=""
  local timing_capture_failed=0
  local -a test_pkg_args
  capture_test_timing_clock started_at_unix_ns started_at_monotonic_ns \
    || timing_capture_failed=1
  # Fail CLOSED on root-setup failure: an unchecked mktemp under `set +e` would export
  # an EMPTY FKST_RUNTIME_ROOT/FKST_DURABLE_ROOT, silently defeating per-package isolation
  # (the engine may then fall back to a shared/default root). A failed setup must fail the unit.
  if ! rt="$(mktemp -d "$roots_parent/rt.XXXXXX")"; then
    echo "error: could not create runtime root for package $name" >&2
    finish_one_package_timing "$report_dir" "$name" "$is_pkg_composed" \
      "$started_at_unix_ns" "$started_at_monotonic_ns" 1 \
      "$timing_capture_failed" "$roots_parent" || true
    return 1
  fi
  if ! dur="$(mktemp -d "$roots_parent/durable.XXXXXX")"; then
    echo "error: could not create durable root for package $name" >&2
    rm -rf "$rt"
    finish_one_package_timing "$report_dir" "$name" "$is_pkg_composed" \
      "$started_at_unix_ns" "$started_at_monotonic_ns" 1 \
      "$timing_capture_failed" "$roots_parent" || true
    return 1
  fi
  export FKST_RUNTIME_ROOT="$rt" FKST_DURABLE_ROOT="$dur"
  echo "=== $name ==="
  if [ "$is_pkg_composed" -eq 1 ]; then
    echo "skip single-package conformance for composed package: $name"
  elif ! run_quiet_pass "$BIN" conformance --project-root "$pkg" --package-root "$pkg"; then
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    report_file="$report_dir/$name.json"
    coverage_dir="$coverage_report_dir/$name"
    # Fail CLOSED if the coverage dir cannot be reset: otherwise a stale coverage.json from
    # a prior run could survive and be accepted below as this run's artifact.
    if ! rm -rf "$coverage_dir" || ! mkdir -p "$coverage_dir"; then
      echo "error: could not prepare coverage directory for package $name" >&2
      rm -rf "$rt" "$dur"
      finish_one_package_timing "$report_dir" "$name" "$is_pkg_composed" \
        "$started_at_unix_ns" "$started_at_monotonic_ns" 1 \
        "$timing_capture_failed" "$roots_parent" || true
      return 1
    fi
    test_project_root="$pkg"; test_pkg_args=(--package-root "$pkg")
    if [ "$is_pkg_composed" -eq 1 ] && ! load_composed_test_roots normal "$name"; then
      result=1
    elif ! run_quiet_keep "$test_failure_filter" \
        "$BIN" test --project-root "$test_project_root" "${test_pkg_args[@]}" --report-json "$report_file" --coverage "$coverage_dir"; then
      result=1
    else
      if [ "$is_pkg_composed" -eq 1 ] && compgen -G "$pkg/tests/run_graph*_test.lua" >/dev/null; then
        if ! load_composed_test_roots graph "$name" || ! run_quiet_keep "$test_failure_filter" \
            "$BIN" test --project-root "$test_project_root" "${test_pkg_args[@]}" --report-json "$report_dir/$name.graph.json" --coverage "$coverage_dir.graph"; then
          result=1
        fi
      fi
      if [ "$result" -eq 0 ] && [ ! -f "$coverage_dir/coverage.json" ]; then
        echo "error: fkst-framework test --coverage did not write coverage.json for $name in $coverage_dir" >&2
        result=1
      fi
    fi
  fi
  rm -rf "$rt" "$dur"
  finish_one_package_timing "$report_dir" "$name" "$is_pkg_composed" \
    "$started_at_unix_ns" "$started_at_monotonic_ns" "$result" \
    "$timing_capture_failed" "$roots_parent" || true
  return "$result"
}
