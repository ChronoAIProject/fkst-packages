#!/usr/bin/env bash
set -euo pipefail

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/bin_bootstrap.sh
. "$script_root/scripts/bin_bootstrap.sh"

worktree="${FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE:-}"
case "$worktree" in
  /*) ;;
  *) bootstrap_die "warm-pinned-bin-invalid-worktree: FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE must be absolute" ;;
esac

prepare_shared_cargo_target() {
  local candidate_target="$worktree/target" common_git_dir shared_target linked_target
  CARGO_TARGET_RESULT="not-applicable"
  [ -f "$worktree/Cargo.toml" ] || return 0

  # A target symlink must remain an ignored build artifact, never candidate source.
  if git -C "$worktree" ls-files --error-unmatch -- target >/dev/null 2>&1; then
    bootstrap_die "warm-pinned-bin-target-tracked: target must remain an untracked cache link"
  fi
  if ! git -C "$worktree" check-ignore -q -- target; then
    bootstrap_die "warm-pinned-bin-target-not-ignored: target must remain ignored"
  fi

  common_git_dir="$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)" \
    || bootstrap_die "warm-pinned-bin-git-identity-unavailable: cannot resolve worktree common git directory"
  common_git_dir="${common_git_dir%/}"
  case "$common_git_dir" in
    /*/.git) ;;
    *) bootstrap_die "warm-pinned-bin-git-identity-invalid: expected an absolute .git common directory" ;;
  esac
  [ -d "$common_git_dir" ] \
    || bootstrap_die "warm-pinned-bin-git-identity-missing: common git directory does not exist"

  shared_target="${common_git_dir%/.git}/target"
  if [ "$candidate_target" = "$shared_target" ]; then
    CARGO_TARGET_RESULT="repository-target"
    return 0
  fi
  mkdir -p "$shared_target"

  if [ -L "$candidate_target" ]; then
    linked_target="$(readlink "$candidate_target")"
    [ "$linked_target" = "$shared_target" ] \
      || bootstrap_die "warm-pinned-bin-target-conflict: target symlink does not select the repository cache"
    CARGO_TARGET_RESULT="hit"
    return 0
  fi
  if [ -e "$candidate_target" ]; then
    CARGO_TARGET_RESULT="local-target"
    return 0
  fi
  if ln -s "$shared_target" "$candidate_target"; then
    CARGO_TARGET_RESULT="linked"
    return 0
  fi

  # A concurrent preparer may have created the same link after the absence check.
  if [ -L "$candidate_target" ] && [ "$(readlink "$candidate_target")" = "$shared_target" ]; then
    CARGO_TARGET_RESULT="hit"
    return 0
  fi
  bootstrap_die "warm-pinned-bin-target-link-failed: cannot connect worktree to repository Cargo target"
}

prepare_shared_cargo_target

# The command runs from trusted project-root content. Candidate pins are data under review and must
# not select source that this host-side preparation process clones and builds.
trusted_root="$PWD"
if [ -f "$trusted_root/.fkst/substrate-ref" ]; then
  pin="$(bootstrap_read_pin "$trusted_root")"
  bootstrap_result=""
  bootstrap_bin_on_total_miss "$trusted_root" bootstrap_result >/dev/null
  if [ "$CARGO_TARGET_RESULT" = "not-applicable" ]; then
    printf 'warm-pinned-bin pin=%s result=%s\n' "$pin" "$bootstrap_result"
  else
    printf 'warm-pinned-bin pin=%s result=%s cargo_target=%s\n' \
      "$pin" "$bootstrap_result" "$CARGO_TARGET_RESULT"
  fi
else
  printf 'warm-pinned-bin pin=none result=%s\n' "$CARGO_TARGET_RESULT"
fi
