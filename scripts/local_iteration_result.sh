#!/usr/bin/env bash
# Total process-result contract for `scripts/run.sh test` and `test-affected`.

LOCAL_ITERATION_RESULT_ARMED=0
LOCAL_ITERATION_RESULT_VERDICT="PASS"
LOCAL_ITERATION_RESULT_FAULT_CLASS="NONE"
LOCAL_ITERATION_RESULT_OUTPUT_FILE=""
LOCAL_ITERATION_RESULT_STATE_FILE=""

local_iteration_result_rank() {
  case "$1:$2" in
    PASS:NONE) printf '%s\n' 0 ;;
    FAIL:SEMANTIC) printf '%s\n' 10 ;;
    FAIL:INFRASTRUCTURE) printf '%s\n' 20 ;;
    FAIL:TOOLCHAIN) printf '%s\n' 30 ;;
    FAIL:CONFIGURATION) printf '%s\n' 40 ;;
    UNKNOWN:UNKNOWN) printf '%s\n' 50 ;;
    *) return 1 ;;
  esac
}

local_iteration_result_write_state() {
  [ -n "${LOCAL_ITERATION_RESULT_STATE_FILE:-}" ] || return 0
  printf '%s:%s\n' "$LOCAL_ITERATION_RESULT_VERDICT" "$LOCAL_ITERATION_RESULT_FAULT_CLASS" \
    > "$LOCAL_ITERATION_RESULT_STATE_FILE"
}

local_iteration_result_merge() {
  local verdict="$1" fault_class="$2" current_rank incoming_rank
  incoming_rank="$(local_iteration_result_rank "$verdict" "$fault_class")" || {
    verdict="UNKNOWN"
    fault_class="UNKNOWN"
    incoming_rank=50
  }
  current_rank="$(local_iteration_result_rank \
    "$LOCAL_ITERATION_RESULT_VERDICT" "$LOCAL_ITERATION_RESULT_FAULT_CLASS")" || current_rank=50
  if [ "$incoming_rank" -gt "$current_rank" ]; then
    LOCAL_ITERATION_RESULT_VERDICT="$verdict"
    LOCAL_ITERATION_RESULT_FAULT_CLASS="$fault_class"
    local_iteration_result_write_state
  fi
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

local_iteration_result_sync_state() {
  local line=""
  [ -n "${LOCAL_ITERATION_RESULT_STATE_FILE:-}" ] || return 0
  [ -f "$LOCAL_ITERATION_RESULT_STATE_FILE" ] || return 0
  IFS= read -r line < "$LOCAL_ITERATION_RESULT_STATE_FILE" || true
  case "$line" in
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
    if [ "$exit_code" -eq 0 ]; then
      local_iteration_result_merge "PASS" "NONE"
    else
      local_iteration_result_unknown
    fi
    return 0
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
  LOCAL_ITERATION_RESULT_VERDICT="PASS"
  LOCAL_ITERATION_RESULT_FAULT_CLASS="NONE"
  LOCAL_ITERATION_RESULT_OUTPUT_FILE="${FKST_LOCAL_ITERATION_RESULT_FILE:-}"
  LOCAL_ITERATION_RESULT_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/fkst-local-result-state.XXXXXX")"
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
  elif [ "$LOCAL_ITERATION_RESULT_VERDICT" = "PASS" ]; then
    LOCAL_ITERATION_RESULT_VERDICT="FAIL"
    LOCAL_ITERATION_RESULT_FAULT_CLASS="INFRASTRUCTURE"
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
