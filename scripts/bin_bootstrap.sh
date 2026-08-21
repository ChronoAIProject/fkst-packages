#!/usr/bin/env bash
# Resolve fkst-framework locators only after rebuilding the artifact from the
# repository's declared fkst-substrate revision.

bootstrap_die() {
  echo "error: $*" >&2
  exit 1
}

bootstrap_cache_root() {
  if [ -n "${FKST_BIN_CACHE_ROOT:-}" ]; then
    printf '%s\n' "$FKST_BIN_CACHE_ROOT"
    return 0
  fi
  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    printf '%s/fkst\n' "$XDG_CACHE_HOME"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    printf '%s/.cache/fkst\n' "$HOME"
    return 0
  fi
  bootstrap_die "cannot determine fkst-framework cache root; set FKST_BIN_CACHE_ROOT"
}

bootstrap_read_pin() {
  local repo_root="$1" pin_source="HEAD:.fkst/substrate-ref" raw pin
  raw="$(git -C "$repo_root" show "$pin_source" 2>/dev/null)" \
    || bootstrap_die "cannot read fkst-substrate source pin: $pin_source"
  pin="$(printf '%s\n' "$raw" | sed -n '1p')"
  pin="${pin%%#*}"
  pin="${pin#"${pin%%[![:space:]]*}"}"
  pin="${pin%"${pin##*[![:space:]]}"}"
  [ -n "$pin" ] || bootstrap_die "empty fkst-substrate source pin: $pin_source"
  printf '%s\n' "$pin"
}

bootstrap_parse_pin() {
  local pin="$1" owner repo ref owner_repo
  if [[ "$pin" == *@* && "$pin" == */* ]]; then
    owner_repo="${pin%@*}"
    ref="${pin#*@}"
    owner="${owner_repo%%/*}"
    repo="${owner_repo#*/}"
  else
    owner="${FKST_SUBSTRATE_OWNER:-ChronoAIProject}"
    repo="${FKST_SUBSTRATE_REPO_NAME:-fkst-substrate}"
    ref="$pin"
  fi
  [ -n "$owner" ] || bootstrap_die "invalid fkst-substrate pin owner: $pin"
  [ -n "$repo" ] || bootstrap_die "invalid fkst-substrate pin repo: $pin"
  [ -n "$ref" ] || bootstrap_die "invalid fkst-substrate pin ref: $pin"
  printf '%s\n%s\n%s\n' "$owner" "$repo" "$ref"
}

bootstrap_cache_bin_path() {
  local repo_root="$1" cache_root="$2" owner="$3" repo="$4" ref="$5"
  python3 -B "$repo_root/scripts/bin_cache.py" "$cache_root" "$owner" "$repo" "$ref"
}

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

bootstrap_candidate_source_commit() {
  local candidate="$1" pin="$2" suffix source_root ref head target status
  suffix="/target/debug/fkst-framework"
  case "$candidate" in
    *"$suffix") source_root="${candidate%"$suffix"}" ;;
    *) return 1 ;;
  esac
  source_root="$(cd "$source_root" 2>/dev/null && pwd -P)" || return 1
  if [ ! -e "$source_root/.git" ] || [ ! -f "$source_root/Cargo.toml" ]; then
    return 1
  fi
  status="$(git -C "$source_root" status --porcelain 2>/dev/null)" || return 1
  [ -z "$status" ] || return 1
  head="$(git -C "$source_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  {
    IFS= read -r _
    IFS= read -r _
    IFS= read -r ref
  } < <(bootstrap_parse_pin "$pin")
  target="$(git -C "$source_root" rev-parse --verify "$ref^{commit}" 2>/dev/null)" \
    || target="$(git -C "$source_root" rev-parse --verify "origin/$ref^{commit}" 2>/dev/null)" \
    || return 1
  [ "$head" = "$target" ] || return 1
  printf '%s\n' "$head"
}

bootstrap_build_artifact() {
  local candidate="$1" pin="$2" source_root source_commit cargo_bin build_root built pending
  case "$candidate" in
    */target/debug/fkst-framework) source_root="${candidate%/target/debug/fkst-framework}" ;;
    *) return 1 ;;
  esac
  source_root="$(cd "$source_root" 2>/dev/null && pwd -P)" || return 1
  source_commit="$(bootstrap_candidate_source_commit "$candidate" "$pin")" || return 1
  cargo_bin="${FKST_CARGO:-cargo}"
  command -v "$cargo_bin" >/dev/null 2>&1 || return 1
  build_root="$(mktemp -d "${TMPDIR:-/tmp}/fkst-framework-build.XXXXXX")" || return 1
  if ! FKST_FRAMEWORK_SOURCE_PIN="$pin" CARGO_TARGET_DIR="$build_root/target" \
    "$cargo_bin" build --manifest-path "$source_root/Cargo.toml" -p fkst-framework 1>&2; then
    rm -rf "$build_root"
    return 1
  fi
  built="$build_root/target/debug/fkst-framework"
  pending="$candidate.tmp.$$"
  if [ ! -x "$built" ] \
      || ! mkdir -p "$(dirname "$candidate")" \
      || ! cp "$built" "$pending" \
      || ! mv "$pending" "$candidate"; then
    rm -f "$pending"
    rm -rf "$build_root"
    return 1
  fi
  rm -rf "$build_root"
  return 0
}

bootstrap_candidate_source_matches_pin() {
  local candidate="$1" pin="$2" source="$3" source_commit
  source_commit="$(bootstrap_candidate_source_commit "$candidate" "$pin")" || source_commit=""
  if [ -z "$source_commit" ]; then
    echo "warning: $source fkst-framework source checkout does not resolve cleanly to declared .fkst/substrate-ref: $pin" >&2
    return 1
  fi
  return 0
}

bootstrap_rebuild_candidate() {
  local candidate="$1" pin="$2" source="$3"
  bootstrap_candidate_source_matches_pin "$candidate" "$pin" "$source" || return 1
  if ! bootstrap_build_artifact "$candidate" "$pin"; then
    echo "warning: $source fkst-framework could not be rebuilt from declared .fkst/substrate-ref: $pin" >&2
    return 1
  fi
  return 0
}

bootstrap_admit_candidate() {
  local candidate="$1" pin="$2" source="$3" mode="$4"
  if [ "$mode" = "readonly" ]; then
    bootstrap_candidate_source_matches_pin "$candidate" "$pin" "$source"
  else
    bootstrap_rebuild_candidate "$candidate" "$pin" "$source"
  fi
}

resolve_bin_contract() {
  local repo_root="$1" mode="${2:-bootstrap}" candidate="" pin owner repo ref cache_root cache_bin
  RESOLVED_BIN=""
  RESOLVE_BIN_ERROR=""
  pin="$(bootstrap_read_pin "$repo_root")"

  if [ -n "${BIN:-}" ]; then
    if [ ! -x "$BIN" ]; then
      if [ "$mode" != "readonly" ] \
          && bootstrap_candidate_source_commit "$BIN" "$pin" >/dev/null 2>&1 \
          && bootstrap_rebuild_candidate "$BIN" "$pin" "explicit BIN"; then
        RESOLVED_BIN="$BIN"
        return 0
      fi
      RESOLVE_BIN_ERROR="explicit BIN is not executable: $BIN"
      return 1
    fi
    if bootstrap_admit_candidate "$BIN" "$pin" "explicit BIN" "$mode"; then
      RESOLVED_BIN="$BIN"
      return 0
    fi
  fi

  if [ -f "$repo_root/.fkst/env" ]; then
    # `|| true`: no BIN= line is fine under set -o pipefail. Strip optional
    # surrounding quotes and a trailing ` # comment`.
    candidate="$(grep -E '^BIN=' "$repo_root/.fkst/env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    candidate="${candidate%%[[:space:]]#*}"
    candidate="${candidate%\"}"; candidate="${candidate#\"}"; candidate="${candidate%\'}"; candidate="${candidate#\'}"
    if [ -n "$candidate" ]; then
      if [ ! -x "$candidate" ]; then
        if [ "$mode" != "readonly" ] \
            && bootstrap_candidate_source_commit "$candidate" "$pin" >/dev/null 2>&1 \
            && bootstrap_rebuild_candidate "$candidate" "$pin" ".fkst/env BIN"; then
          RESOLVED_BIN="$candidate"
          return 0
        fi
        RESOLVE_BIN_ERROR=".fkst/env BIN is not executable: $candidate"
        return 1
      fi
      if bootstrap_admit_candidate "$candidate" "$pin" ".fkst/env BIN" "$mode"; then
        RESOLVED_BIN="$candidate"
        return 0
      fi
    fi
  fi

  if command -v fkst-framework >/dev/null 2>&1; then
    candidate="$(command -v fkst-framework)"
    if bootstrap_admit_candidate "$candidate" "$pin" "PATH" "$mode"; then
      RESOLVED_BIN="$candidate"
      return 0
    fi
  fi

  candidate="$repo_root/../fkst-substrate/target/debug/fkst-framework"
  if [ -x "$candidate" ]; then
    if bootstrap_admit_candidate "$candidate" "$pin" "sibling checkout" "$mode"; then
      RESOLVED_BIN="$candidate"
      return 0
    fi
  fi

  if [ "$mode" = "readonly" ]; then
    if [ -z "${FKST_NO_AUTOBUILD:-}" ]; then
      if [ -n "$pin" ]; then
        {
          IFS= read -r owner
          IFS= read -r repo
          IFS= read -r ref
        } < <(bootstrap_parse_pin "$pin" 2>/dev/null || true)
        cache_root="$(bootstrap_cache_root 2>/dev/null || true)"
        if [ -n "${owner:-}" ] && [ -n "${repo:-}" ] && [ -n "${ref:-}" ] && [ -n "$cache_root" ]; then
          cache_bin="$(bootstrap_cache_bin_path "$repo_root" "$cache_root" "$owner" "$repo" "$ref" 2>/dev/null || true)"
          if [ -x "$cache_bin" ] && bootstrap_candidate_source_matches_pin "$cache_bin" "$pin" "pinned cache"; then
            RESOLVED_BIN="$cache_bin"
            return 0
          fi
        fi
      fi
    fi
    RESOLVE_BIN_ERROR="set BIN to an executable fkst-framework, put fkst-framework on PATH, build ../fkst-substrate, or run scripts/run.sh build"
    return 1
  fi

  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    RESOLVE_BIN_ERROR="fkst-framework binary is not executable in CI: ${BIN:-<unset>}"
    return 1
  fi

  echo "no fkst-framework locator resolved to declared .fkst/substrate-ref; checking pinned source cache" >&2
  RESOLVED_BIN="$(bootstrap_bin_on_total_miss "$repo_root")" || return $?
  return 0
}

# Serialize verifier-controlled rebuilds of the shared pinned source checkout.

bootstrap_with_lock() {
  local lock_dir="$1" timeout="${FKST_BIN_BOOTSTRAP_LOCK_TIMEOUT:-600}" waited=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      bootstrap_die "timed out waiting for fkst-framework bootstrap lock: $lock_dir"
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

bootstrap_checkout_ref() {
  local checkout_dir="$1" ref="$2"
  if git -C "$checkout_dir" checkout --detach "$ref" 1>&2; then
    return 0
  fi
  git -C "$checkout_dir" checkout --detach "origin/$ref" 1>&2
}

bootstrap_set_result() {
  local variable_name="${1:-}" result="$2"
  [ -z "$variable_name" ] || printf -v "$variable_name" '%s' "$result"
}

bootstrap_bin_on_total_miss() {
  local repo_root="$1" result_var="${2:-}" pin owner repo ref cache_root bin_path checkout_dir parent_dir lock_dir repo_url

  if [ -n "${FKST_NO_AUTOBUILD:-}" ]; then
    echo "error: fkst-framework binary not found and FKST_NO_AUTOBUILD is set; refusing network clone or build" >&2
    echo "  fix: set BIN to an executable fkst-framework, put fkst-framework on PATH, build ../fkst-substrate, or unset FKST_NO_AUTOBUILD" >&2
    exit 1
  fi
  command -v git >/dev/null 2>&1 || bootstrap_die "required tool missing for fkst-framework bootstrap: git"
  command -v cargo >/dev/null 2>&1 || bootstrap_die "required tool missing for fkst-framework bootstrap: cargo"
  command -v python3 >/dev/null 2>&1 || bootstrap_die "required tool missing for fkst-framework bootstrap: python3"

  pin="$(bootstrap_read_pin "$repo_root")"
  {
    IFS= read -r owner
    IFS= read -r repo
    IFS= read -r ref
  } < <(bootstrap_parse_pin "$pin")
  cache_root="$(bootstrap_cache_root)"
  bin_path="$(bootstrap_cache_bin_path "$repo_root" "$cache_root" "$owner" "$repo" "$ref")"

  checkout_dir="${bin_path%/target/debug/fkst-framework}"
  parent_dir="$(dirname "$checkout_dir")"
  mkdir -p "$parent_dir"
  lock_dir="$checkout_dir.lock"

  bootstrap_with_lock "$lock_dir"
  if bootstrap_candidate_source_commit "$bin_path" "$pin" >/dev/null 2>&1; then
    if ! bootstrap_build_artifact "$bin_path" "$pin"; then
      rm -rf "$lock_dir"
      return 1
    fi
    rm -rf "$lock_dir"
    bootstrap_set_result "$result_var" build
    printf '%s\n' "$bin_path"
    return 0
  fi

  echo "fkst-framework pinned source cache miss for $pin; bootstrapping pinned source (build starting)" >&2
  if (
    repo_url="https://github.com/$owner/$repo.git"
    if [ -d "$checkout_dir/.git" ]; then
      git -C "$checkout_dir" fetch --tags origin '+refs/heads/*:refs/remotes/origin/*' 1>&2 || exit $?
    else
      rm -rf "$checkout_dir"
      git clone --no-checkout "$repo_url" "$checkout_dir" 1>&2 || exit $?
      git -C "$checkout_dir" fetch --tags origin '+refs/heads/*:refs/remotes/origin/*' 1>&2 || exit $?
    fi

    bootstrap_checkout_ref "$checkout_dir" "$ref" || exit $?
    bootstrap_build_artifact "$bin_path" "$pin" \
      || bootstrap_die "fkst-framework bootstrap could not build the declared source: $bin_path"
    printf '%s\n' "$bin_path"
  ); then
    rm -rf "$lock_dir"
    bootstrap_set_result "$result_var" build
  else
    local rc=$?
    rm -rf "$lock_dir"
    return "$rc"
  fi
}
