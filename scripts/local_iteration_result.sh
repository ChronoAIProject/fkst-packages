#!/usr/bin/env bash
# Total process-result contract for `scripts/run.sh test` and `test-affected`.

LOCAL_ITERATION_RESULT_ARMED=0
LOCAL_ITERATION_RESULT_VERDICT=""
LOCAL_ITERATION_RESULT_FAULT_CLASS=""
LOCAL_ITERATION_RESULT_OUTPUT_FILE=""
LOCAL_ITERATION_RESULT_STATE_FILE=""

local_iteration_result_is_valid() {
  case "$1:$2" in
    PASS:NONE|FAIL:SEMANTIC|FAIL:CONFIGURATION|FAIL:TOOLCHAIN|FAIL:INFRASTRUCTURE|UNKNOWN:UNKNOWN)
      return 0
      ;;
    *) return 1 ;;
  esac
}

local_iteration_result_write_state() {
  [ -n "${LOCAL_ITERATION_RESULT_STATE_FILE:-}" ] || return 0
  if [ -n "$LOCAL_ITERATION_RESULT_VERDICT" ]; then
    printf '%s:%s\n' "$LOCAL_ITERATION_RESULT_VERDICT" "$LOCAL_ITERATION_RESULT_FAULT_CLASS" \
      > "$LOCAL_ITERATION_RESULT_STATE_FILE"
  else
    : > "$LOCAL_ITERATION_RESULT_STATE_FILE"
  fi
}

local_iteration_result_merge() {
  local verdict="$1" fault_class="$2" current_pair incoming_pair
  if ! local_iteration_result_is_valid "$verdict" "$fault_class"; then
    verdict="UNKNOWN"
    fault_class="UNKNOWN"
  fi
  incoming_pair="$verdict:$fault_class"
  current_pair="$LOCAL_ITERATION_RESULT_VERDICT:$LOCAL_ITERATION_RESULT_FAULT_CLASS"

  if [ -z "$LOCAL_ITERATION_RESULT_VERDICT" ] || [ "$current_pair" = "PASS:NONE" ]; then
    LOCAL_ITERATION_RESULT_VERDICT="$verdict"
    LOCAL_ITERATION_RESULT_FAULT_CLASS="$fault_class"
  elif [ "$current_pair" = "$incoming_pair" ] || [ "$incoming_pair" = "PASS:NONE" ]; then
    return 0
  else
    LOCAL_ITERATION_RESULT_VERDICT="UNKNOWN"
    LOCAL_ITERATION_RESULT_FAULT_CLASS="UNKNOWN"
  fi
  local_iteration_result_write_state
}

local_iteration_result_fail() {
  case "$1" in
    SEMANTIC|CONFIGURATION|TOOLCHAIN|INFRASTRUCTURE)
      local_iteration_result_merge "FAIL" "$1"
      ;;
    *)
      local_iteration_result_merge "UNKNOWN" "UNKNOWN"
      ;;
  esac
}

local_iteration_result_unknown() {
  local_iteration_result_merge "UNKNOWN" "UNKNOWN"
}

local_iteration_result_pass() {
  local_iteration_result_merge "PASS" "NONE"
}

local_iteration_result_sync_state() {
  local line=""
  [ -n "${LOCAL_ITERATION_RESULT_STATE_FILE:-}" ] || return 0
  [ -f "$LOCAL_ITERATION_RESULT_STATE_FILE" ] || return 0
  IFS= read -r line < "$LOCAL_ITERATION_RESULT_STATE_FILE" || true
  case "$line" in
    "") return 0 ;;
    PASS:NONE) local_iteration_result_merge "PASS" "NONE" ;;
    FAIL:SEMANTIC) local_iteration_result_merge "FAIL" "SEMANTIC" ;;
    FAIL:CONFIGURATION) local_iteration_result_merge "FAIL" "CONFIGURATION" ;;
    FAIL:TOOLCHAIN) local_iteration_result_merge "FAIL" "TOOLCHAIN" ;;
    FAIL:INFRASTRUCTURE) local_iteration_result_merge "FAIL" "INFRASTRUCTURE" ;;
    UNKNOWN:UNKNOWN) local_iteration_result_merge "UNKNOWN" "UNKNOWN" ;;
    *) local_iteration_result_unknown ;;
  esac
}

local_iteration_result_merge_file() {
  local path="$1" exit_code="$2" marker="" lines verdict fault_class
  if [ ! -f "$path" ] || [ ! -s "$path" ]; then
    local_iteration_result_unknown
    return 1
  fi

  lines="$(wc -l < "$path" | tr -d ' ')"
  IFS= read -r marker < "$path" || true
  if [ "$lines" != "1" ]; then
    local_iteration_result_unknown
    return 1
  fi
  case "$marker" in
    FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE)
      verdict="PASS"; fault_class="NONE"
      ;;
    FKST_LOCAL_ITERATION_RESULT:v2:FAIL:SEMANTIC)
      verdict="FAIL"; fault_class="SEMANTIC"
      ;;
    FKST_LOCAL_ITERATION_RESULT:v2:FAIL:CONFIGURATION)
      verdict="FAIL"; fault_class="CONFIGURATION"
      ;;
    FKST_LOCAL_ITERATION_RESULT:v2:FAIL:TOOLCHAIN)
      verdict="FAIL"; fault_class="TOOLCHAIN"
      ;;
    FKST_LOCAL_ITERATION_RESULT:v2:FAIL:INFRASTRUCTURE)
      verdict="FAIL"; fault_class="INFRASTRUCTURE"
      ;;
    FKST_LOCAL_ITERATION_RESULT:v2:UNKNOWN:UNKNOWN)
      verdict="UNKNOWN"; fault_class="UNKNOWN"
      ;;
    *)
      local_iteration_result_unknown
      return 1
      ;;
  esac
  if { [ "$exit_code" -eq 0 ] && [ "$verdict" != "PASS" ]; } \
    || { [ "$exit_code" -ne 0 ] && [ "$verdict" = "PASS" ]; }; then
    local_iteration_result_unknown
    return 1
  fi
  local_iteration_result_merge "$verdict" "$fault_class"
}

local_iteration_result_arm() {
  LOCAL_ITERATION_RESULT_ARMED=1
  LOCAL_ITERATION_RESULT_VERDICT=""
  LOCAL_ITERATION_RESULT_FAULT_CLASS=""
  LOCAL_ITERATION_RESULT_OUTPUT_FILE="${FKST_LOCAL_ITERATION_RESULT_FILE:-}"
  unset FKST_LOCAL_ITERATION_RESULT_FILE
  LOCAL_ITERATION_RESULT_STATE_FILE=""
  # These slots become cleanup-owned only when cmd_test creates their roots.
  unset TEST_HERMETIC_RUNTIME_ROOT TEST_HERMETIC_DURABLE_ROOT TEST_HERMETIC_PKG_ROOTS
  trap 'local_iteration_result_finish' EXIT
  if ! LOCAL_ITERATION_RESULT_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/fkst-local-result-state.XXXXXX")"; then
    local_iteration_result_fail "INFRASTRUCTURE"
    return 1
  fi
  export FKST_LOCAL_ITERATION_STATE_FILE="$LOCAL_ITERATION_RESULT_STATE_FILE"
  local_iteration_result_write_state
}

local_iteration_result_cleanup_test_roots() {
  local path
  for path in \
    "${TEST_HERMETIC_RUNTIME_ROOT:-}" \
    "${TEST_HERMETIC_DURABLE_ROOT:-}" \
    "${TEST_HERMETIC_PKG_ROOTS:-}"; do
    [ -n "$path" ] && rm -rf "$path"
  done
  return 0
}

local_iteration_result_finish() {
  local exit_code=$? marker
  trap - EXIT
  local_iteration_result_sync_state
  if [ "$exit_code" -eq 0 ]; then
    if [ "$LOCAL_ITERATION_RESULT_VERDICT" != "PASS" ] \
      || [ "$LOCAL_ITERATION_RESULT_FAULT_CLASS" != "NONE" ]; then
      LOCAL_ITERATION_RESULT_VERDICT="UNKNOWN"
      LOCAL_ITERATION_RESULT_FAULT_CLASS="UNKNOWN"
      exit_code=1
    fi
  elif [ -z "$LOCAL_ITERATION_RESULT_VERDICT" ] \
    || { [ "$LOCAL_ITERATION_RESULT_VERDICT" = "PASS" ] \
      && [ "$LOCAL_ITERATION_RESULT_FAULT_CLASS" = "NONE" ]; }; then
    LOCAL_ITERATION_RESULT_VERDICT="UNKNOWN"
    LOCAL_ITERATION_RESULT_FAULT_CLASS="UNKNOWN"
  fi

  local_iteration_result_cleanup_test_roots
  disarm_test_deadline
  marker="FKST_LOCAL_ITERATION_RESULT:v2:${LOCAL_ITERATION_RESULT_VERDICT}:${LOCAL_ITERATION_RESULT_FAULT_CLASS}"
  if [ -n "$LOCAL_ITERATION_RESULT_OUTPUT_FILE" ]; then
    printf '%s\n' "$marker" > "$LOCAL_ITERATION_RESULT_OUTPUT_FILE"
  else
    printf '%s\n' "$marker" >&2
  fi
  rm -f "$LOCAL_ITERATION_RESULT_STATE_FILE"
  exit "$exit_code"
}
