#!/usr/bin/env bash
# Generic dev runner for fkst packages.
#
#   scripts/run.sh test [-v|--verbose] [package ...]
#       Run self-test, flat package conformance, package tests, and composed
#       graph conformance. Tests use fresh runtime/durable roots and keep only
#       failure-relevant lines unless -v/--verbose or FKST_TEST_VERBOSE=1 is set.
#
#   scripts/run.sh check
#       Run hermetic repository checks and engine workspace dependency validation.
#
#   scripts/run.sh host --host-root <HOST> [--platform-root <PKGSRC>] [--local-packages <dir>] -- <check|test|supervise [args]>
#       Run shared fkst-packages orchestration for a host repo. The host passes
#       only its root/config; this runner owns BIN resolution, source ratchets,
#       engine package-root wiring, and host_run.sh supervise delegation.
#
#   scripts/run.sh doctor
#       Run read-only preflight checks for git/cargo/rustc, fkst-framework BIN,
#       codex, gh auth, and relevant FKST_* host facts.
#
#   scripts/run.sh doctor github-devloop-ops
#       Run the read-only package-side saga doctor against the configured
#       running GitHub repository. Exact engine queue/DLQ depths remain
#       unavailable here and need fkst-framework doctor support.
#
#   scripts/run.sh board [--refresh] [--ttl seconds] [--stall seconds]
#       Render the local github-devloop observability board from engine observe
#       data, using a local non-authoritative TTL cache unless --refresh is set.
#
#   scripts/run.sh ratchet-migration-dry-run <891|892> [--slice-size N]
#       Print a deterministic child issue body for a code-owned allowlist ratchet
#       parent. This is read-only and never creates issues, writes comments, closes
#       parents, or runs issue-provided inventory commands.
#
#   scripts/run.sh health [--refresh] [--ttl seconds] [--stall seconds]
#       Print only the current HEALTHY / anomaly verdict from the board renderer.
#
#   scripts/run.sh test-composed
#       Run only composed graph conformance for composed package graphs.
#
#   scripts/run.sh test-affected
#       Run scoped local verification for paths changed from the integration base.
#
#   scripts/run.sh run <package> <department> [event-json]
#   scripts/run.sh run <package> <department> --event-file <path>
#       One-shot run a department through fkst-framework run, decode emitted
#       RAISED events, and dump the runtime scratch tree. Never sets
#       FKST_GITHUB_WRITE.
#
#   scripts/run.sh supervise --project-root <HOST> --platform-root <PKGSRC> --platform-packages "<names>" [--host-packages "<names>"] --durable-root <path> [--runtime-root <fresh-scratch-root>] [--restart]
#       Start the real fkst-framework supervise event loop for one host. Runtime
#       root is scratch and defaults to a fresh temp dir; explicit --runtime-root
#       is used as the fresh scratch root for this launch.
#       Platform package roots are resolved from the target fkst.workspace.toml
#       and fkst.lock, not from ad hoc package-root construction.
#       Durable root is mandatory and reused. --restart SIGKILLs the prior host-run supervise
#       recorded for that durable root. FKST_GITHUB_WRITE passes through
#       (unset = dry-run).
#
#   scripts/run.sh supervise <package>
#       Backward-compatible package-local supervise wrapper. Uses .fkst/run/runtime
#       and .fkst/run/durable by default and requires FKST_RATE_POOL_ROOT from the
#       host so named external-command rate pools are shared across instances.
#
#   scripts/run.sh build
#       Local-only helper: update the fkst-substrate dev checkout and build
#       fkst-framework. test/run/supervise ensure a traceable local BIN is built
#       from the current fkst-substrate working tree before running.
#
# fkst-framework binary resolution (priority): $BIN > repo .fkst/env `BIN=` > PATH >
# sibling ../fkst-substrate/target/debug/fkst-framework > pinned source cache
# clone/build fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FKST_DIR="$ROOT/.fkst"
SOURCE_PACKAGES_ROOT="$ROOT/packages"
LOCAL_PACKAGES_ROOT="$FKST_DIR/local-packages"
EXTERNAL_PACKAGES_ROOT="$FKST_DIR/packages"
DEFAULT_RUNTIME_ROOT="$FKST_DIR/run/runtime"
DEFAULT_DURABLE_ROOT="$FKST_DIR/run/durable"

# shellcheck source=scripts/bin_bootstrap.sh
. "$ROOT/scripts/bin_bootstrap.sh"
# shellcheck source=scripts/host_run.sh
. "$ROOT/scripts/host_run.sh"
# shellcheck source=scripts/host_entry.sh
. "$ROOT/scripts/host_entry.sh"
# shellcheck source=scripts/composed_manifest.sh
. "$ROOT/scripts/composed_manifest.sh"
# shellcheck source=scripts/local_iteration_result.sh
. "$ROOT/scripts/local_iteration_result.sh"
# shellcheck source=scripts/run_bin.sh
. "$ROOT/scripts/run_bin.sh"
# shellcheck source=scripts/test_affected.sh
. "$ROOT/scripts/test_affected.sh"
# shellcheck source=scripts/test_parallel.sh
. "$ROOT/scripts/test_parallel.sh"
# shellcheck source=scripts/test_coverage.sh
. "$ROOT/scripts/test_coverage.sh"
# shellcheck source=scripts/test_deadline.sh
. "$ROOT/scripts/test_deadline.sh"
# shellcheck source=scripts/run_department.sh
. "$ROOT/scripts/run_department.sh"

shell_single_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

default_board_cmd() {
  printf 'FKST_NO_AUTOBUILD=1 %s board' "$(shell_single_quote "$ROOT/scripts/run.sh")"
}

competence_gate_base_ref() {
  if [ -n "${FKST_COMPETENCE_BASE_REF:-}" ]; then
    printf '%s\n' "$FKST_COMPETENCE_BASE_REF"
    return 0
  fi
  if [ -n "${GITHUB_BASE_REF:-}" ]; then
    if git -C "$ROOT" rev-parse --verify --quiet "origin/$GITHUB_BASE_REF" >/dev/null; then
      printf 'origin/%s\n' "$GITHUB_BASE_REF"
    else
      printf '%s\n' "$GITHUB_BASE_REF"
    fi
    return 0
  fi
  if git -C "$ROOT" rev-parse --verify --quiet origin/integration >/dev/null; then
    printf '%s\n' "origin/integration"
    return 0
  fi
  if git -C "$ROOT" rev-parse --verify --quiet integration >/dev/null; then
    printf '%s\n' "integration"
    return 0
  fi
  return 1
}

ensure_package_view() {
  mkdir -p "$FKST_DIR"
  ln -sfn ../packages "$LOCAL_PACKAGES_ROOT"
}

package_root_for_name() {
  local name="$1"
  if [ -d "$LOCAL_PACKAGES_ROOT/$name" ]; then
    printf '%s\n' "$LOCAL_PACKAGES_ROOT/$name"
    return 0
  fi
  if [ -d "$EXTERNAL_PACKAGES_ROOT/$name" ]; then
    printf '%s\n' "$EXTERNAL_PACKAGES_ROOT/$name"
    return 0
  fi
  return 1
}

usage() {
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cmd_check() {
  local fail=0 competence_base_ref="" pool
  unset FKST_R9_TRACE_ROOT
  pool="$(detect_pool_size)"
  # Every unit below is an independent process (its own repo-read + unique tempdir),
  # so the check verdict is a commutative AND-fold — running them concurrently changes
  # only wall-clock, not which checks run or their pass/fail. Keep the FULL set.
  local -a units=(
    'python3 -B "$ROOT/scripts/check_repo.py"'
    'python3 -B "$ROOT/scripts/ci_workflow_test.py"'
    'python3 -B "$ROOT/scripts/ratchet_base_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_fkst_layout.py"'
    'python3 -B "$ROOT/scripts/check_repo_dedup_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_intent_bounded_replay_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_intent_bounded_replay_checker_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_intent_delivery_authorization_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_intent_bounded_replay_semantic_tree_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_content_truncation_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_bot_login_mediation_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_fanout_only_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_coverage_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_devloop_decouple_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_devloop_godlib_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_devloop_installer_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_integration_coverage_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_intake_default_surface_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_dead_letter_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_dead_locals_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_producer_liveness_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_monotone_gate_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_test_graphql.py"'
    'python3 -B "$ROOT/scripts/check_repo_interface_test.py"'
    'python3 -B "$ROOT/scripts/lua_coverage_to_lcov_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_library_layering_test.py"'
    'python3 -B "$ROOT/scripts/run_script_contract_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_gh_git_adapter_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_github_content_ingress_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_error_class_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_library_error_class_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_dependency_cycle_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_shell_out_to_self_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_hidden_state_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_std_dependency_model_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_saga_head_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_namespaced_queue_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_fkst_layout_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_restart_lifecycle_test.py"'
    'python3 -B "$ROOT/scripts/check_repo_restart_preflight_test.py"'
    'python3 -B "$ROOT/scripts/bin_cache_test.py"'
    'python3 -B "$ROOT/scripts/bin_bootstrap_test.py"'
    'python3 -B "$ROOT/scripts/host_entry_test.py"'
    'python3 -B "$ROOT/scripts/run_bin_test.py"'
    'python3 -B "$ROOT/scripts/host_run_test.py"'
    'python3 -B "$ROOT/scripts/host_run_restart_test.py"'
    'python3 -B "$ROOT/scripts/host_run_source_identity_test.py"'
    'python3 -B "$ROOT/scripts/host_run_local_iteration_test.py"'
    'python3 -B "$ROOT/scripts/host_run_process_group_test.py"'
    'python3 -B "$ROOT/scripts/host_profile_scaffold_test.py"'
    'python3 -B "$ROOT/scripts/run_sh_coverage_test.py"'
    'python3 -B "$ROOT/scripts/run_sh_test_affected_test.py"'
    'python3 -B "$ROOT/scripts/run_sh_test_deadline_test.py"'
    'python3 -B "$ROOT/scripts/composed_manifest_test.py"'
    'python3 -B "$ROOT/scripts/board_test.py"'
    'python3 -B "$ROOT/scripts/lifecycle_board_fact_test.py"'
    'python3 -B "$ROOT/scripts/doctor_test.py"'
    'python3 -B "$ROOT/scripts/ratchet_migration_slicer_test.py"'
    'python3 -B "$ROOT/scripts/competence_gate_test.py"'
    'python3 -B "$ROOT/scripts/test_parallel_test.py"'
  )
  # competence gate needs a base ref resolved once (a git read) before it can run.
  if competence_base_ref="$(competence_gate_base_ref)"; then
    units+=('python3 -B "$ROOT/scripts/competence_gate.py" --base-ref "$competence_base_ref"')
  else
    echo "error: competence gate requires FKST_COMPETENCE_BASE_REF, GITHUB_BASE_REF, or an integration ref" >&2
    local_iteration_result_fail "CONFIGURATION"
    fail=1
  fi
  run_units_parallel "$pool" "${units[@]}" || fail=$(( fail + $? ))
  # Producer-owned exit codes distinguish actionable repository violations from an unevaluable
  # repository-check configuration. Only a single shared typed code establishes attribution;
  # mixed or bare-nonzero failures keep the honest UNKNOWN.
  case "${RUN_UNITS_FAIL_CODES:-}" in
    10) local_iteration_result_fail "SEMANTIC" ;;
    11) local_iteration_result_fail "CONFIGURATION" ;;
  esac
  # engine workspace dependency validation runs only after the ratchets pass, exactly
  # as before: resolve_bin may exit on an unresolvable BIN, so it must not preempt the
  # checks (whose failure output some checker unit-tests assert on).
  if [ "$fail" -eq 0 ]; then
    resolve_bin
    "$BIN" deps --project-root "$ROOT" || fail=1
    python3 -B "$ROOT/scripts/check_host_library_surfaces.py" --bin "$BIN" --source-root "$ROOT" || fail=1
  fi
  return "$fail"
}

check_sdk_primitives() {
  local probe_dir report_file
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/fkst-sdk-probe.XXXXXX")"
  mkdir -p "$probe_dir/tests"
  cat > "$probe_dir/fkst.workspace.toml" <<'TOML'
[workspace]
units = ["."]
TOML
  cat > "$probe_dir/fkst.toml" <<'TOML'
kind = "package"
name = "sdk-probe"

[code]
root = "."
TOML
  printf 'return {}\n' > "$probe_dir/core.lua"
  cat > "$probe_dir/tests/sdk_primitives_test.lua" <<'LUA'
local t = fkst.test

local function cjk_char()
  return string.char(0xe6, 0xb5, 0x8b)
end

local function emoji_char()
  return string.char(0xf0, 0x9f, 0x98, 0x80)
end

local function assert_valid_utf8(value)
  local ok, len = pcall(utf8.len, tostring(value or ""))
  t.is_true(ok and len ~= nil)
end

return {
  test_truncate_utf8_sdk_primitive_is_deployed = function()
    t.eq(type(truncate_utf8), "function")
    local cjk = cjk_char()
    local emoji = emoji_char()
    local mixed = "ab" .. cjk .. "cd"

    t.eq(truncate_utf8(mixed, 2), "ab")
    t.eq(truncate_utf8(mixed, 3), "ab")
    t.eq(truncate_utf8(mixed, 4), "ab")
    t.eq(truncate_utf8(mixed, 5), "ab" .. cjk)
    t.eq(truncate_utf8(mixed, 6), "ab" .. cjk .. "c")
    t.eq(truncate_utf8("", 3), "")
    t.eq(truncate_utf8(cjk, 2), "")
    t.eq(truncate_utf8(emoji .. "x", 3), "")
    t.eq(truncate_utf8("ab" .. emoji .. "x", 6), "ab" .. emoji)
    assert_valid_utf8(truncate_utf8(mixed, 1))
    assert_valid_utf8(truncate_utf8(mixed, 7))
    assert_valid_utf8(truncate_utf8("ab" .. emoji .. "x", 5))
    assert_valid_utf8(truncate_utf8("ab" .. emoji .. "x", 6))
  end,
}
LUA

  report_file="$probe_dir/report.json"
  if ! "$BIN" test --project-root "$probe_dir" --package-root "$probe_dir" --report-json "$report_file"; then
    rm -rf "$probe_dir"
    echo "error: required SDK primitive is unavailable or invalid: truncate_utf8(s, max_bytes)" >&2
    return 1
  fi
  rm -rf "$probe_dir"
  echo "OK: SDK primitive truncate_utf8 is available in BIN: $BIN"
}

# Run "$@"; unless verbose (cmd_test's flag), drop advisory `PASS` lines from its
# combined output so only failures surface. Returns the command's own exit code
# (via PIPESTATUS, not grep's). The `set +e`/`set -e` guard makes it safe in any
# caller context: the inner grep matching nothing on an all-pass run must not
# trip the script-wide `set -e`.
run_quiet_pass() {
  if [ -n "${verbose:-}${FKST_TEST_VERBOSE:-}" ]; then "$@"; return $?; fi
  local rc had_e=""
  case $- in *e*) had_e=1 ;; esac
  set +e
  "$@" 2>&1 | grep -vE '^PASS '
  rc=${PIPESTATUS[0]}
  # Restore the CALLER's errexit posture (not a hard set -e): run_one_package runs
  # under `set +e` in the pool subshell and must stay that way so a later benign
  # nonzero standalone command cannot abort it before it records its exit code.
  if [ -n "$had_e" ]; then set -e; else set +e; fi
  return "$rc"
}

# Run "$2..."; unless verbose, KEEP only stdout lines matching the regex in $1
# (the inverse of run_quiet_pass — allowlist for the noisy engine test stream).
# Returns the command's own exit code via PIPESTATUS, not grep's, so an all-pass
# run (grep still matches the tally) and a failing run both report correctly.
# Same `set +e`/`set -e` guard so a failing package neither aborts the run nor is
# swallowed: the loop continues and the count stays accurate.
run_quiet_keep() {
  local keep="$1"; shift
  if [ -n "${verbose:-}${FKST_TEST_VERBOSE:-}" ]; then "$@"; return $?; fi
  local rc had_e=""
  case $- in *e*) had_e=1 ;; esac
  set +e
  "$@" 2>&1 | grep -E -- "$keep"
  rc=${PIPESTATUS[0]}
  # Restore the caller's errexit posture (see run_quiet_pass).
  if [ -n "$had_e" ]; then set -e; else set +e; fi
  return "$rc"
}

load_composed_test_roots() { local script; script="$(bash "$ROOT/scripts/composed_test_graph_roots.sh" "$1" "$2")" || return 1; eval "$script"; }

# The scratch report directory is the public artifact boundary for per-package `--report-json`
# files and the nested `timing/` namespace. A successful timing observation writes exactly one
# `timing/<unit>.timing.json` record per attempted unit with schema `fkst.test.unit_timing.v1` and
# exactly these fields: `schema` and `unit` strings; `composed` boolean; integer
# `started_at_unix_ns` and `ended_at_unix_ns` epoch timestamps bracketing the complete unit attempt;
# numeric `elapsed_ms` derived from the corresponding monotonic-clock readings; and normalized
# integer `exit_status` (0 or 1). Each interval includes the end clock adapter's own invocation
# latency, including interpreter startup: about 20 ms per read on the measured host. This systematic
# positive bias is material for sub-second units; the schema is for critical-path analysis of units
# taking tens of seconds, not exact short-unit execution cost. The schema has no phase fields.
# The timing writer atomically renames a private temporary file into this directory, so cmd_test must
# keep its package-roots parent and scratch report directory on the same filesystem; both are
# currently created beneath `${TMPDIR:-/tmp}`.
# Observation failure warns, leaves no final timing record, and never changes the unit verdict. When
# FKST_TEST_REPORT_DIR is set (same shape as FKST_LUA_COVERAGE_OUTPUT), publication must remain
# recursive so both top-level reports and nested timing records arrive. Publication failure likewise
# warns without changing the run verdict; the scratch report directory is removed in every case.
finish_test_reports() {
  local dir="$1" dest="${FKST_TEST_REPORT_DIR:-}"
  if [ -n "$dest" ] && [ -d "$dir" ]; then
    if mkdir -p "$dest" && cp -R "$dir"/. "$dest"/ 2>/dev/null; then
      echo "test reports published to $dest"
    else
      echo "warning: could not publish test reports to $dest" >&2
    fi
  fi
  rm -rf "$dir"
}

cmd_test() {
  local ran=0 fail=0 pkg name target selected verbose="${FKST_TEST_VERBOSE:-}" rc pool
  local report_dir coverage_report_dir coverage_file
  local coverage_artifacts=()
  local -a targets=() pkg_units=() ran_names=() ordered_pkgs=()
  # Keep failure-relevant lines only unless verbose; per-test FAIL is anchored so
  # expected error-path logs containing tag=FAILURE do not match.
  local test_failure_filter='^FAIL |passed, [0-9]+ failed|panic'
  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--verbose) verbose=1 ;;
      -*) local_iteration_result_fail "CONFIGURATION"; echo "unknown test flag: $1" >&2; exit 2 ;;
      *) targets+=("$1") ;;
    esac
    shift
  done

  TEST_HERMETIC_RUNTIME_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fkst-test-rt.XXXXXX")"
  TEST_HERMETIC_DURABLE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fkst-test-durable.XXXXXX")"
  TEST_HERMETIC_PKG_ROOTS="$(mktemp -d "${TMPDIR:-/tmp}/fkst-test-pkgroots.XXXXXX")"
  export FKST_RUNTIME_ROOT="$TEST_HERMETIC_RUNTIME_ROOT"
  export FKST_DURABLE_ROOT="$TEST_HERMETIC_DURABLE_ROOT"
  export FKST_R9_TRACE_ROOT="$TEST_HERMETIC_RUNTIME_ROOT/r9-traces"
  if ! mkdir -p "$FKST_R9_TRACE_ROOT"; then
    local_iteration_result_fail "INFRASTRUCTURE"
    return 1
  fi
  unset FKST_GITHUB_WRITE
  unset FKST_SUPERVISOR_PID
  echo "test hermetic: FKST_RUNTIME_ROOT=$FKST_RUNTIME_ROOT FKST_DURABLE_ROOT=$FKST_DURABLE_ROOT (ambient overridden)"

  report_dir="$(mktemp -d "${TMPDIR:-/tmp}/fkst-test-reports.XXXXXX")"
  coverage_report_dir="$FKST_RUNTIME_ROOT/package-lua-coverage"

  echo "=== self-test ==="
  if ! run_self_test_with_optional_lua_coverage; then
    fail=$((fail + 1))
  fi

  echo "=== sdk-primitives ==="
  if ! run_quiet_pass check_sdk_primitives; then
    fail=$((fail + 1))
  fi

  ensure_package_view
  for target in ${targets[@]+"${targets[@]}"}; do
    selected=0
    for pkg in "$SOURCE_PACKAGES_ROOT"/*/; do
      [ -d "$pkg" ] || continue
      name="$(basename "$pkg")"
      if [ "$name" = "$target" ] && [ -d "$LOCAL_PACKAGES_ROOT/$name" ]; then
        selected=1
        break
      fi
    done
    if [ "$selected" -eq 0 ]; then
      local_iteration_result_fail "CONFIGURATION"
      echo "no packages matched for '$target'" >&2
      exit 1
    fi
  done
  pool="$(detect_pool_size)"
  # Each package is an independent test unit; build the unit list, then run them
  # concurrently. Every unit gets its own ephemeral runtime/durable roots inside
  # run_one_package, and its report/coverage land in $name-keyed collection dirs, so
  # the aggregated pass/fail + coverage fan-in is identical to the former serial loop.
  # Dispatch order is longest-first, not the directory glob's alphabetical order; ordering
  # changes only WHEN each unit launches, never which units run or their verdicts. See
  # test_units_longest_first in scripts/test_parallel.sh for why and for the key's limits.
  while IFS= read -r src_pkg; do
    [ -n "$src_pkg" ] || continue
    ordered_pkgs+=("$src_pkg")
  done < <(test_units_longest_first "$SOURCE_PACKAGES_ROOT")
  for src_pkg in ${ordered_pkgs[@]+"${ordered_pkgs[@]}"}; do
    [ -d "$src_pkg" ] || continue
    name="$(basename "$src_pkg")"
    pkg="$LOCAL_PACKAGES_ROOT/$name"
    [ -d "$pkg" ] || continue
    if [ "${#targets[@]}" -gt 0 ]; then
      selected=0
      for target in "${targets[@]}"; do
        if [ "$name" = "$target" ]; then selected=1; break; fi
      done
      [ "$selected" -eq 1 ] || continue
    fi
    ran=$((ran + 1))
    rc=0; is_composed "$pkg" || rc=$?
    case "$rc" in
      0) pkg_units+=("run_one_package $(printf '%q' "$name") $(printf '%q' "$pkg") 1 $(printf '%q' "$report_dir") $(printf '%q' "$coverage_report_dir") $(printf '%q' "$TEST_HERMETIC_PKG_ROOTS") $(printf '%q' "$test_failure_filter")"); ran_names+=("$name") ;;
      1) pkg_units+=("run_one_package $(printf '%q' "$name") $(printf '%q' "$pkg") 0 $(printf '%q' "$report_dir") $(printf '%q' "$coverage_report_dir") $(printf '%q' "$TEST_HERMETIC_PKG_ROOTS") $(printf '%q' "$test_failure_filter")"); ran_names+=("$name") ;;
      *) echo "error: failed to read package composition for $pkg" >&2; fail=$((fail + 1)) ;;
    esac
  done
  if [ "${#pkg_units[@]}" -gt 0 ]; then
    run_units_parallel "$pool" "${pkg_units[@]}" || fail=$(( fail + $? ))
  fi
  # Collect per-package coverage artifacts from their deterministic $name-keyed paths.
  # Only consumed when fail==0 (all packages passed), matching the serial version's
  # ratchet precondition; a run_one_package failure already bumped fail above.
  for name in ${ran_names[@]+"${ran_names[@]}"}; do
    coverage_file="$coverage_report_dir/$name/coverage.json"
    [ -f "$coverage_file" ] && coverage_artifacts+=("$coverage_file")
  done
  if [ "$ran" -eq 0 ]; then
    local_iteration_result_fail "CONFIGURATION"
    echo "no packages matched" >&2
    exit 1
  fi
  if [ "${#targets[@]}" -eq 0 ]; then
    if ! cmd_test_composed; then
      fail=$((fail + 1))
    fi
    if [ "$fail" -eq 0 ]; then
      if ! enforce_lua_coverage_ratchet -- "${coverage_artifacts[@]}"; then
        fail=$((fail + 1))
      fi
    fi
    if [ "$fail" -eq 0 ]; then
      if ! check_test_file_coverage "$report_dir"; then
        fail=$((fail + 1))
      fi
    fi
  fi
  if [ "$fail" -ne 0 ]; then
    if test_reports_establish_semantic_failure "$report_dir" "$fail"; then
      local_iteration_result_fail "SEMANTIC"
    else
      [ -n "$LOCAL_ITERATION_RESULT_VERDICT" ] || local_iteration_result_unknown
    fi
    finish_test_reports "$report_dir"
    echo "FAILED: $fail failure(s) across $ran package(s)" >&2; exit 1
  fi
  finish_test_reports "$report_dir"
  echo "OK: $ran package(s)"
  local_iteration_result_pass
}

collect_composed_package() {
  local name="$1" pkg dep deps rc
  pkg="$(package_root_for_name "$name")" || { echo "error: composed package dependency not found: $name" >&2; return 1; }
  [ -d "$pkg" ] || { echo "error: composed package dependency not found: $name" >&2; return 1; }
  case " ${COMPOSED_SEEN[*]-} " in
    *" $name "*) return 0 ;;
  esac
  COMPOSED_SEEN+=("$name")
  set +e; deps="$(composition_siblings_of "$pkg")"; rc=$?; set -e
  case "$rc" in
    0)
      while IFS= read -r dep || [ -n "$dep" ]; do
        [ -n "$dep" ] || continue
        collect_composed_package "$dep" || return 1
      done <<< "$deps"
      ;;
    1) return 0 ;;
    *) echo "error: failed to read package composition for $pkg" >&2; return 1 ;;
  esac
}

cmd_test_composed() {
  local pkg name args project_root rc hermetic_var hermetic_env
  ensure_package_view
  COMPOSED_SEEN=()
  for pkg in "$LOCAL_PACKAGES_ROOT"/*/ "$EXTERNAL_PACKAGES_ROOT"/*/; do
    [ -d "$pkg" ] || continue
    rc=0; is_composed "$pkg" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *) echo "error: failed to read package composition for $pkg" >&2; return 1 ;;
    esac
    name="$(basename "$pkg")"
    collect_composed_package "$name" || return 1
  done
  if [ "${#COMPOSED_SEEN[@]}" -eq 0 ]; then
    echo "no composed packages matched"
    return 0
  fi

  hermetic_env=(env)
  for hermetic_var in FKST_GITHUB_BOT_LOGIN FKST_GITHUB_CLAIM_LABEL_EXCLUSIVE FKST_GITHUB_CLAIM_LABEL_OWNER_DIGEST_HEX_LENGTH FKST_GITHUB_CLAIM_LABEL_SUFFIX FKST_GITHUB_CLAIM_MODE FKST_GITHUB_REPO FKST_GITHUB_WRITE FKST_GITHUB_PROXY_POLL_LABEL_PREFIX FKST_DEVLOOP_UPSTREAM_BRANCH FKST_DEVLOOP_INTEGRATION_BRANCH FKST_DEVLOOP_INTAKE_MILESTONE_NUMBERS FKST_DEVLOOP_FORK_GRACE_HOURS FKST_DEVLOOP_MAX_INFLIGHT FKST_DEVLOOP_MANAGED_SIBLING_REPOS FKST_DEVLOOP_MANAGED_BOT_LOGINS FKST_DEVLOOP_ROLLUP_MERGE FKST_DEVLOOP_ROLLUP_AUTOFIX FKST_DEVLOOP_ROLLUP_RED_WINDOW_MINUTES FKST_DEVLOOP_RELEASE_NOTES_FALLBACK FKST_DEVLOOP_CONFLICT_LOG_CMD FKST_DEVLOOP_BOARD_CMD FKST_DEVLOOP_TEST_COMMAND FKST_DEVLOOP_LOCAL_TEST_COMMAND FKST_DEVLOOP_CACHE_PREPARATION_COMMAND FKST_PROJECT_ROOT FKST_CODEX_REPOSITORY_ROOTS FKST_OUTPUT_LANG FKST_DEBUG_STAMP; do
    hermetic_env+=(-u "$hermetic_var")
  done

  args=()
  project_root="$(package_root_for_name "${COMPOSED_SEEN[0]}")" || return 1
  for name in "${COMPOSED_SEEN[@]}"; do
    pkg="$(package_root_for_name "$name")" || return 1
    args+=(--package-root "$pkg")
  done
  for pkg in "$LOCAL_PACKAGES_ROOT"/*/ "$EXTERNAL_PACKAGES_ROOT"/*/; do
    [ -d "$pkg" ] || continue
    case " ${COMPOSED_SEEN[*]} " in
      *" $(basename "$pkg") "*) continue ;;
    esac
    args+=(--package-root "${pkg%/}")
  done
  echo "=== composed conformance ==="
  run_quiet_pass "${hermetic_env[@]}" "$BIN" conformance --project-root "$project_root" "${args[@]}"
}

cmd_doctor() {
  if [ "$#" -eq 0 ]; then
    "$BASH" "$ROOT/scripts/doctor.sh"
    return $?
  fi

  local pkg="${1:-}"
  shift
  case "$pkg" in
    github-devloop-ops)
      if [ "$#" -ne 0 ]; then
        echo "usage: scripts/run.sh doctor github-devloop-ops" >&2
        exit 2
      fi
      resolve_bin
      ensure_fresh_bin
      ensure_package_view
      local pkgdir rootdir args
      pkgdir="$(package_root_for_name github-devloop-ops)" || { echo "error: no package named github-devloop-ops" >&2; exit 1; }
      local lua="$pkgdir/departments/doctor/main.lua"
      [ -f "$lua" ] || { echo "error: no saga doctor at $lua" >&2; exit 1; }
      args=("$BIN" run "$lua" --project-root "$ROOT")
      for rootdir in "$LOCAL_PACKAGES_ROOT"/*/ "$EXTERNAL_PACKAGES_ROOT"/*/; do
        [ -d "$rootdir" ] || continue
        args+=(--package-root "${rootdir%/}")
      done
      args+=(--owner-namespace github-devloop-ops --event '{"queue":"devloop_doctor_tick","payload":{}}')
      "${args[@]}" \
        | grep -vE '^RAISED:'
      ;;
    --running|--system)
      if [ "${1:-}" != "github-devloop-ops" ]; then
        echo "usage: scripts/run.sh doctor [github-devloop-ops|--running github-devloop-ops|--system github-devloop-ops]" >&2
        exit 2
      fi
      shift
      cmd_doctor github-devloop-ops "$@"
      ;;
    *)
      echo "usage: scripts/run.sh doctor [github-devloop-ops|--running github-devloop-ops|--system github-devloop-ops]" >&2
      exit 2
      ;;
  esac
}

cmd_board() {
  local durable="${FKST_DURABLE_ROOT:-$DEFAULT_DURABLE_ROOT}"
  local cache="$FKST_DIR/run/board-cache.json"
  python3 -B "$ROOT/scripts/board.py" \
    --bin "$BIN" \
    --durable-root "$durable" \
    --cache "$cache" \
    "$@"
}

cmd_health() {
  cmd_board --health "$@"
}

cmd_ratchet_migration_dry_run() {
  python3 -B "$ROOT/packages/github-ratchet-migration-slicer/tools/ratchet_migration_slicer.py" --repo-root "$ROOT" "$@"
}

cmd_supervise_old() {
  local pkg="${1:-}"
  if [ -z "$pkg" ]; then
    echo "usage: scripts/run.sh supervise <package>" >&2; exit 1
  fi
  if [ -z "${FKST_RATE_POOL_ROOT:-}" ]; then
    echo "error: FKST_RATE_POOL_ROOT is required for supervise so gh rate pools share one host-stable budget" >&2
    echo "  set FKST_RATE_POOL_ROOT to the same host-stable directory for every supervise instance that spends the GitHub quota" >&2
    exit 1
  fi
  case "$FKST_RATE_POOL_ROOT" in
    /*) ;;
    *)
      echo "error: FKST_RATE_POOL_ROOT must be an absolute host-stable directory path" >&2
      exit 1
      ;;
  esac
  ensure_package_view
  local pkgdir rootdir args
  pkgdir="$(package_root_for_name "$pkg")" || { echo "error: no package named $pkg" >&2; exit 1; }
  [ -d "$pkgdir" ] || { echo "error: no package at $pkgdir" >&2; exit 1; }

  local project_root rt durable
  project_root="$(host_run_abs_path "${FKST_PROJECT_ROOT:-$pkgdir}")"
  host_run_validate_local_iteration_test_command_for "$ROOT" "$pkg"
  rt="${FKST_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
  durable="${FKST_DURABLE_ROOT:-$DEFAULT_DURABLE_ROOT}"
  mkdir -p "$rt" "$durable"
  if [ "$rt" = "$durable" ]; then
    echo "error: FKST_RUNTIME_ROOT and FKST_DURABLE_ROOT resolved to the same directory" >&2
    exit 1
  fi
  export FKST_RUNTIME_ROOT="$rt"
  export FKST_DURABLE_ROOT="$durable"
  export FKST_PROJECT_ROOT="$project_root"
  local repository_roots=("$ROOT")
  if [ -n "${BIN_REPOSITORY_ROOT:-}" ]; then
    repository_roots+=("$BIN_REPOSITORY_ROOT")
  fi
  host_run_export_codex_repository_roots "${repository_roots[@]}" || exit $?
  export FKST_DEVLOOP_BOARD_CMD="${FKST_DEVLOOP_BOARD_CMD:-$(default_board_cmd)}"

  echo "BIN=$BIN"
  echo "FKST_RUNTIME_ROOT=$FKST_RUNTIME_ROOT"
  echo "FKST_DURABLE_ROOT=$FKST_DURABLE_ROOT"
  echo "FKST_RATE_POOL_ROOT=$FKST_RATE_POOL_ROOT"
  echo "This starts the real supervise event loop in the foreground. Press Ctrl-C to stop."
  args=("$BIN" supervise --project-root "$project_root")
  for rootdir in "$LOCAL_PACKAGES_ROOT"/*/ "$EXTERNAL_PACKAGES_ROOT"/*/; do
    [ -d "$rootdir" ] || continue
    args+=(--package-root "${rootdir%/}")
  done
  args+=(--framework-bin "$BIN")
  echo "exec: ${args[*]}"
  exec "${args[@]}"
}

cmd_supervise() {
  case "${1:-}" in
    --*) host_run_supervise_contract "$@" ;;
    *) cmd_supervise_old "$@" ;;
  esac
}

cmd_build() {
  local substrate="${FKST_SUBSTRATE:-}"
  if [ -z "$substrate" ]; then
    if [ -d "/Users/auric/fkst-substrate/.git" ]; then
      substrate="/Users/auric/fkst-substrate"
    elif [ -d "$ROOT/../fkst-substrate/.git" ]; then
      substrate="$ROOT/../fkst-substrate"
    fi
  fi
  if [ -z "$substrate" ] || [ ! -d "$substrate/.git" ]; then
    echo "error: fkst-substrate checkout not found (set FKST_SUBSTRATE, use /Users/auric/fkst-substrate, or sibling ../fkst-substrate)." >&2
    exit 1
  fi

  local branch
  branch="$(git -C "$substrate" branch --show-current)"
  if [ "$branch" != "dev" ]; then
    echo "error: refusing to build from $substrate on branch '$branch'; switch to dev first." >&2
    exit 1
  fi

  git -C "$substrate" pull
  cargo build --manifest-path "$substrate/Cargo.toml" -p fkst-framework
  echo "OK: built $substrate/target/debug/fkst-framework"
}

main() {
  # Bound the whole test-family run BEFORE dispatch (covers cmd_check too); see scripts/test_deadline.sh.
  case "${1:-}" in
    check|test-composed) arm_test_deadline; trap 'disarm_test_deadline' EXIT ;;
    test|test-affected) local_iteration_result_arm; arm_test_deadline ;;
  esac
  case "${1:-}" in
    check) shift; cmd_check "$@" ;;
    host) shift; cmd_host "$@" ;;
    doctor) shift; cmd_doctor "$@" ;;
    board) shift; resolve_bin; ensure_fresh_bin; cmd_board "$@" ;;
    health) shift; resolve_bin; ensure_fresh_bin; cmd_health "$@" ;;
    ratchet-migration-dry-run) shift; cmd_ratchet_migration_dry_run "$@" ;;
    test) shift
      # Quiet cmd_check's advisory warnings during a test run unless verbose;
      # surface its full output only when it hard-fails (non-zero). `run.sh check`
      # and `test -v`/FKST_TEST_VERBOSE=1 still show every warning.
      case " $* " in *" -v "*|*" --verbose "*) _tv=1 ;; *) _tv="${FKST_TEST_VERBOSE:-}" ;; esac
      if [ -n "$_tv" ]; then
        if ! cmd_check; then
          local_iteration_result_sync_state
          [ -n "$LOCAL_ITERATION_RESULT_VERDICT" ] || local_iteration_result_unknown
          return 1
        fi
      elif ! _chk_out="$(cmd_check 2>&1)"; then
        local_iteration_result_sync_state
        [ -n "$LOCAL_ITERATION_RESULT_VERDICT" ] || local_iteration_result_unknown
        printf '%s\n' "$_chk_out"; return 1
      fi
      resolve_bin; ensure_fresh_bin; cmd_test "$@" ;;
    test-affected) shift; cmd_test_affected "$@" ;;
    test-composed) shift; cmd_check; resolve_bin; ensure_fresh_bin; cmd_test_composed "$@" ;;
    run)  shift; resolve_bin; ensure_fresh_bin; cmd_run "$@" ;;
    supervise) shift; resolve_bin; ensure_fresh_bin; cmd_supervise "$@" ;;
    build) shift; cmd_build "$@" ;;
    -h|--help|help|"") usage ;;
    *) echo "unknown subcommand: $1" >&2; usage; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
