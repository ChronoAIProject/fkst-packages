#!/usr/bin/env bash
# fkst-framework BIN resolution and source-checkout context for scripts/run.sh.

BIN_REPOSITORY_ROOT=""

resolve_bin() {
  if ! resolve_bin_contract "$ROOT" "bootstrap"; then
    local_iteration_result_fail "TOOLCHAIN"
    echo "error: $RESOLVE_BIN_ERROR" >&2
    if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "  CI must build fkst-substrate and inject BIN; scripts/run.sh will not build in CI." >&2
    fi
    exit 1
  fi
  BIN="$RESOLVED_BIN"
  export BIN
}

warn_if_substrate_behind() {
  local substrate="$1" behind
  behind="$(git -C "$substrate" rev-list --count HEAD..origin/dev 2>/dev/null)" || behind=""
  if [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
    echo "warning: fkst-substrate checkout '$substrate' is $behind commit(s) behind its origin/dev;" >&2
    echo "         the BIN may be stale (missing newer engine primitives). scripts/run.sh builds from the" >&2
    echo "         CURRENT checkout and does NOT git-pull — run 'git pull' in that checkout, then rebuild to refresh." >&2
  fi
}

ensure_fresh_bin() {
  local phys substrate suffix
  BIN_REPOSITORY_ROOT=""
  suffix="/target/debug/fkst-framework"
  phys="$(resolve_phys_path "$BIN")" || phys="$BIN"
  if [[ "$phys" == *"$suffix" ]]; then
    substrate="${phys%"$suffix"}"
  else
    substrate=""
  fi
  if [ -n "$substrate" ] && [ -d "$substrate/.git" ] && [ -f "$substrate/Cargo.toml" ]; then
    BIN_REPOSITORY_ROOT="$substrate"
  else
    substrate=""
  fi

  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    return 0
  fi

  if [ -z "$substrate" ]; then
    if [ -z "${FKST_NO_AUTOBUILD:-}" ]; then
      echo "warning: cannot trace BIN to an fkst-substrate checkout: $BIN" >&2
    fi
    return 0
  fi

  warn_if_substrate_behind "$substrate"
}
