#!/usr/bin/env bash
# Resolve fkst-framework locators only when the artifact proves it was built
# from the repository's declared fkst-substrate revision.

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

bootstrap_artifact_sha256() {
  python3 -B - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as artifact:
    for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

bootstrap_candidate_source_commit() {
  local candidate="$1" pin="$2" phys suffix source_root ref head target status
  suffix="/target/debug/fkst-framework"
  phys="$(resolve_phys_path "$candidate")" || return 1
  case "$phys" in
    *"$suffix") source_root="${phys%"$suffix"}" ;;
    *) return 1 ;;
  esac
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

bootstrap_artifact_provenance_path() {
  printf '%s.fkst-provenance-v1\n' "$1"
}

bootstrap_record_artifact_provenance() {
  local candidate="$1" pin="$2" source_commit digest provenance pending
  [ -x "$candidate" ] || return 1
  source_commit="$(bootstrap_candidate_source_commit "$candidate" "$pin")" || return 1
  digest="$(bootstrap_artifact_sha256 "$candidate")" || return 1
  provenance="$(bootstrap_artifact_provenance_path "$candidate")"
  pending="$provenance.tmp.$$"
  printf '%s\n' \
    "schema=fkst-framework-artifact-provenance.v1" \
    "declared_pin=$pin" \
    "source_commit=$source_commit" \
    "artifact_sha256=$digest" > "$pending" || return 1
  mv "$pending" "$provenance"
}

bootstrap_artifact_provenance_matches() {
  local candidate="$1" pin="$2" source_commit="$3" provenance schema declared source digest actual
  provenance="$(bootstrap_artifact_provenance_path "$candidate")"
  [ -f "$provenance" ] && [ ! -L "$provenance" ] || return 1
  schema="$(sed -n '1p' "$provenance")"
  declared="$(sed -n '2p' "$provenance")"
  source="$(sed -n '3p' "$provenance")"
  digest="$(sed -n '4p' "$provenance")"
  [ "$schema" = "schema=fkst-framework-artifact-provenance.v1" ] || return 1
  [ "$declared" = "declared_pin=$pin" ] || return 1
  [ "$source" = "source_commit=$source_commit" ] || return 1
  case "$digest" in
    artifact_sha256=????????????????????????????????????????????????????????????????) ;;
    *) return 1 ;;
  esac
  actual="$(bootstrap_artifact_sha256 "$candidate")" || return 1
  [ "$digest" = "artifact_sha256=$actual" ]
}

bootstrap_candidate_matches_pin() {
  local candidate="$1" pin="$2" source="$3" source_commit
  source_commit="$(bootstrap_candidate_source_commit "$candidate" "$pin")" || source_commit=""
  if [ -z "$source_commit" ]; then
    echo "warning: $source fkst-framework source checkout does not resolve cleanly to declared .fkst/substrate-ref: $pin" >&2
    return 1
  fi
  if ! bootstrap_artifact_provenance_matches "$candidate" "$pin" "$source_commit"; then
    echo "warning: $source fkst-framework lacks builder provenance binding its bytes to declared .fkst/substrate-ref: $pin" >&2
    return 1
  fi
  return 0
}

resolve_bin_contract() {
  local repo_root="$1" mode="${2:-bootstrap}" candidate="" pin owner repo ref cache_root cache_bin
  RESOLVED_BIN=""
  RESOLVE_BIN_ERROR=""
  pin="$(bootstrap_read_pin "$repo_root")"

  if [ -n "${BIN:-}" ]; then
    if [ ! -x "$BIN" ]; then
      RESOLVE_BIN_ERROR="explicit BIN is not executable: $BIN"
      return 1
    fi
    if bootstrap_candidate_matches_pin "$BIN" "$pin" "explicit BIN"; then
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
        RESOLVE_BIN_ERROR=".fkst/env BIN is not executable: $candidate"
        return 1
      fi
      if bootstrap_candidate_matches_pin "$candidate" "$pin" ".fkst/env BIN"; then
        RESOLVED_BIN="$candidate"
        return 0
      fi
    fi
  fi

  if command -v fkst-framework >/dev/null 2>&1; then
    candidate="$(command -v fkst-framework)"
    if bootstrap_candidate_matches_pin "$candidate" "$pin" "PATH"; then
      RESOLVED_BIN="$candidate"
      return 0
    fi
  fi

  candidate="$repo_root/../fkst-substrate/target/debug/fkst-framework"
  if [ -x "$candidate" ]; then
    if bootstrap_candidate_matches_pin "$candidate" "$pin" "sibling checkout"; then
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
          if [ -x "$cache_bin" ] && bootstrap_candidate_matches_pin "$cache_bin" "$pin" "pinned cache"; then
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

# Single flight: exactly one process builds the pinned binary; every other
# process reuses the artifact it produces. Returns 0 holding the lock, or
# BOOTSTRAP_LOCK_ARTIFACT_READY when the holder finished and "$bin_path" is
# usable — waiting out the whole timeout and dying would discard a binary that
# already exists.
BOOTSTRAP_LOCK_ARTIFACT_READY=2

bootstrap_with_lock() {
  local lock_dir="$1" bin_path="$2" pin="$3" timeout="${FKST_BIN_BOOTSTRAP_LOCK_TIMEOUT:-600}" waited=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ -x "$bin_path" ] \
      && bootstrap_candidate_matches_pin "$bin_path" "$pin" "pinned cache under bootstrap lock" 2>/dev/null; then
      return "$BOOTSTRAP_LOCK_ARTIFACT_READY"
    fi
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
  if [ -x "$bin_path" ] && bootstrap_candidate_matches_pin "$bin_path" "$pin" "pinned cache"; then
    bootstrap_set_result "$result_var" hit
    printf '%s\n' "$bin_path"
    return 0
  fi

  checkout_dir="${bin_path%/target/debug/fkst-framework}"
  parent_dir="$(dirname "$checkout_dir")"
  mkdir -p "$parent_dir"
  lock_dir="$checkout_dir.lock"

  local lock_rc
  while true; do
    lock_rc=0
    bootstrap_with_lock "$lock_dir" "$bin_path" "$pin" || lock_rc=$?
    if [ "$lock_rc" -eq "$BOOTSTRAP_LOCK_ARTIFACT_READY" ]; then
      if [ -x "$bin_path" ] && bootstrap_candidate_matches_pin "$bin_path" "$pin" "pinned cache"; then
        bootstrap_set_result "$result_var" hit
        printf '%s\n' "$bin_path"
        return 0
      fi
      continue
    fi
    if [ "$lock_rc" -ne 0 ]; then
      return "$lock_rc"
    fi
    break
  done
  if [ -x "$bin_path" ] && bootstrap_candidate_matches_pin "$bin_path" "$pin" "pinned cache"; then
    rm -rf "$lock_dir"
    bootstrap_set_result "$result_var" hit
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
    FKST_FRAMEWORK_SOURCE_PIN="$pin" cargo build --manifest-path "$checkout_dir/Cargo.toml" -p fkst-framework 1>&2 || exit $?
    [ -x "$bin_path" ] || bootstrap_die "fkst-framework bootstrap did not produce an executable binary: $bin_path"
    bootstrap_record_artifact_provenance "$bin_path" "$pin" \
      || bootstrap_die "fkst-framework bootstrap could not record artifact provenance: $bin_path"
    bootstrap_candidate_matches_pin "$bin_path" "$pin" "fresh pinned build" \
      || bootstrap_die "fkst-framework bootstrap produced an artifact with mismatched source provenance: $bin_path"
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
