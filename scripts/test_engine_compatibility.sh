#!/usr/bin/env bash
# Explicit historical-engine compatibility lane for github-devloop.

liveness_engine_bin_ref() {
  local bin="$1" source_root
  case "$bin" in
    */target/debug/fkst-framework) source_root="${bin%/target/debug/fkst-framework}" ;;
    *) return 1 ;;
  esac
  git -C "$source_root" rev-parse HEAD 2>/dev/null
}

cmd_test_engine_compatibility() {
  local refs_file="$SOURCE_PACKAGES_ROOT/github-devloop/tests/liveness_failure_domain_engine_refs.env"
  local name bin expected_ref actual_ref
  if [ "$#" -ne 0 ]; then
    local_iteration_result_fail "CONFIGURATION"
    echo "usage: scripts/run.sh test-engine-compatibility" >&2
    return 1
  fi
  if [ ! -f "$refs_file" ]; then
    local_iteration_result_fail "CONFIGURATION"
    echo "error: missing liveness engine compatibility refs: $refs_file" >&2
    return 1
  fi
  # shellcheck source=packages/github-devloop/tests/liveness_failure_domain_engine_refs.env
  . "$refs_file"
  for name in FKST_LIVENESS_PRE_ADVANCE_ENGINE_REF FKST_LIVENESS_POST_ADVANCE_ENGINE_REF; do
    expected_ref="${!name:-}"
    if [[ ! "$expected_ref" =~ ^[0-9a-f]{40}$ ]]; then
      local_iteration_result_fail "CONFIGURATION"
      echo "error: $name must be a full lowercase commit SHA" >&2
      return 1
    fi
    export "$name"
  done
  for name in FKST_LIVENESS_PRE_ADVANCE_ENGINE_BIN FKST_LIVENESS_POST_ADVANCE_ENGINE_BIN; do
    bin="${!name:-}"
    if [ -z "$bin" ] || [ ! -x "$bin" ]; then
      local_iteration_result_fail "CONFIGURATION"
      echo "error: $name must name a pre-provisioned executable fkst-framework" >&2
      return 1
    fi
    case "$name" in
      FKST_LIVENESS_PRE_ADVANCE_ENGINE_BIN) expected_ref="$FKST_LIVENESS_PRE_ADVANCE_ENGINE_REF" ;;
      FKST_LIVENESS_POST_ADVANCE_ENGINE_BIN) expected_ref="$FKST_LIVENESS_POST_ADVANCE_ENGINE_REF" ;;
    esac
    actual_ref="$(liveness_engine_bin_ref "$bin")" || actual_ref=""
    if [ "$actual_ref" != "$expected_ref" ]; then
      local_iteration_result_fail "CONFIGURATION"
      echo "error: $name resolved revision ${actual_ref:-<unknown>}, expected $expected_ref" >&2
      return 1
    fi
    export "$name"
  done
  export FKST_LIVENESS_ENGINE_COMPATIBILITY=1
  resolve_bin
  ensure_fresh_bin
  cmd_test github-devloop
}
