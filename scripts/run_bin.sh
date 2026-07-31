#!/usr/bin/env bash
# fkst-framework BIN resolution and local-source freshness for scripts/run.sh.

resolve_bin() {
  local prior_verdict="${LOCAL_ITERATION_RESULT_VERDICT:-PASS}"
  local prior_fault_class="${LOCAL_ITERATION_RESULT_FAULT_CLASS:-NONE}"
  if [ "${LOCAL_ITERATION_RESULT_ARMED:-0}" -eq 1 ]; then
    local_iteration_result_fail "TOOLCHAIN"
  fi
  if ! resolve_bin_contract "$ROOT" "bootstrap"; then
    echo "error: $RESOLVE_BIN_ERROR" >&2
    if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "  CI must build fkst-substrate and inject BIN; scripts/run.sh will not build in CI." >&2
    fi
    exit 1
  fi
  BIN="$RESOLVED_BIN"
  export BIN
  if [ "${LOCAL_ITERATION_RESULT_ARMED:-0}" -eq 1 ]; then
    LOCAL_ITERATION_RESULT_VERDICT="$prior_verdict"
    LOCAL_ITERATION_RESULT_FAULT_CLASS="$prior_fault_class"
    local_iteration_result_write_state
  fi
}

# Resolve a path to its physical location, following file symlinks too (portable:
# no realpath / `readlink -f` dependency, works with macOS BSD readlink).
resolve_phys_path() {
  local p="$1" target dir
  while [ -L "$p" ]; do
    target="$(readlink "$p")" || break
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$target" ;;
    esac
  done
  dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$p")"
}

warn_if_substrate_behind() {
  local substrate="$1" behind
  behind="$(git -C "$substrate" rev-list --count HEAD..origin/dev 2>/dev/null)" || behind=""
  if [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
    echo "warning: fkst-substrate checkout '$substrate' is $behind commit(s) behind its origin/dev;" >&2
    echo "         the BIN may be stale (missing newer engine primitives). scripts/run.sh builds from the" >&2
    echo "         CURRENT checkout and does NOT git-pull — run 'dogfood.sh sync' (or git pull + rebuild) to refresh." >&2
  fi
}

ensure_fresh_bin() {
  local prior_verdict="${LOCAL_ITERATION_RESULT_VERDICT:-PASS}"
  local prior_fault_class="${LOCAL_ITERATION_RESULT_FAULT_CLASS:-NONE}"
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    return 0
  fi

  if [ "${LOCAL_ITERATION_RESULT_ARMED:-0}" -eq 1 ]; then
    local_iteration_result_fail "TOOLCHAIN"
  fi

  local phys substrate suffix
  suffix="/target/debug/fkst-framework"
  phys="$(resolve_phys_path "$BIN")" || phys="$BIN"
  if [[ "$phys" == *"$suffix" ]]; then
    substrate="${phys%"$suffix"}"
  else
    substrate=""
  fi
  if [ -z "$substrate" ] || [ ! -d "$substrate/.git" ] || [ ! -f "$substrate/Cargo.toml" ]; then
    if [ -z "${FKST_NO_AUTOBUILD:-}" ]; then
      echo "warning: cannot trace BIN to an fkst-substrate checkout; skipping freshness build: $BIN" >&2
    fi
    LOCAL_ITERATION_RESULT_VERDICT="$prior_verdict"
    LOCAL_ITERATION_RESULT_FAULT_CLASS="$prior_fault_class"
    local_iteration_result_write_state
    return 0
  fi

  warn_if_substrate_behind "$substrate"

  if [ -n "${FKST_NO_AUTOBUILD:-}" ]; then
    echo "warning: FKST_NO_AUTOBUILD set; skipping fkst-framework freshness build" >&2
    LOCAL_ITERATION_RESULT_VERDICT="$prior_verdict"
    LOCAL_ITERATION_RESULT_FAULT_CLASS="$prior_fault_class"
    local_iteration_result_write_state
    return 0
  fi

  echo "ensuring fkst-framework is built from current source: $substrate" >&2
  local build_out
  if ! build_out="$(cargo build --manifest-path "$substrate/Cargo.toml" -p fkst-framework 2>&1)"; then
    printf '%s\n' "$build_out" >&2
    echo "error: fkst-framework freshness build failed; refusing to continue with a potentially stale BIN" >&2
    exit 1
  fi
  LOCAL_ITERATION_RESULT_VERDICT="$prior_verdict"
  LOCAL_ITERATION_RESULT_FAULT_CLASS="$prior_fault_class"
  local_iteration_result_write_state
}
