#!/usr/bin/env bash
# Forward-sync and intent-diff lifecycle operations for dogfood run checkouts.

restore_generated_workspace_scratch() { # $1 worktree dir
  local wt="$1"
  [ -f "$wt/fkst.workspace.toml" ] || return 0
  git -C "$wt" diff --quiet -- fkst.workspace.toml 2>/dev/null && return 0
  python3 "$_self_dir/workspace_manifest.py" is-generated-scratch "$wt" "$DEVLOOP_PKGS" >/dev/null || return 0
  echo "    restoring generated fkst.workspace.toml scratch before branch sync"
  git -C "$wt" checkout -q -- fkst.workspace.toml 2>/dev/null
}

sync_to_run_branch() { # $1 worktree dir
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || { echo "  ! $1 is not a git worktree"; return 1; }
  git -C "$1" fetch origin "$INTEGRATION_BRANCH" -q 2>/dev/null
  local target; target=$(git -C "$1" rev-parse --short "origin/$INTEGRATION_BRANCH" 2>/dev/null)
  # checkout -B (not reset --hard): leaves the checkout actually ON the integration branch
  # tracking origin/<integration>, instead of pointing a stale local 'dev' ref at integration content.
  local note; note=$(git -C "$1" checkout -q -B "$INTEGRATION_BRANCH" "origin/$INTEGRATION_BRANCH" 2>&1 | tail -1)
  # Verify the checkout actually REACHED target, then self-heal. A checkout that aborts (working-tree
  # obstruction, a file<->symlink/dir transition racing the running supervise, a dirty tree) otherwise
  # leaves the clone on STALE code while the function returns ok and the supervise silently launches
  # stale — the exact "supervise silently re-running already-fixed defects" failure this tooling exists
  # to prevent. Self-heal forcefully (reset --hard + clean reaches the fetched ref regardless of the
  # obstruction; clean -fd keeps gitignored .fkst/ runtime), then re-assert the branch so the checkout
  # stays ON <integration>. If it STILL cannot reach target (deep corruption ensure_run_checkout should
  # have re-cloned), fail loud with STALE-CHECKOUT so the operator and doctor (pkg-stale) catch it.
  if [ -n "$target" ] && [ "$(git -C "$1" rev-parse --short HEAD 2>/dev/null)" != "$target" ]; then
    git -C "$1" reset --hard "origin/$INTEGRATION_BRANCH" -q 2>/dev/null
    git -C "$1" clean -fdq 2>/dev/null
    git -C "$1" checkout -q -B "$INTEGRATION_BRANCH" "origin/$INTEGRATION_BRANCH" 2>/dev/null
    note="self-healed stale checkout (was: ${note:-checkout-failed})"
  fi
  local head; head=$(git -C "$1" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$target" ] && [ "$head" != "$target" ]; then
    echo "  $1 -> STALE-CHECKOUT: still $head, target $target ($note) ($INTEGRATION_BRANCH)"
    return 1
  fi
  echo "  $1 -> $head${note:+ ($note)} ($INTEGRATION_BRANCH)"
}

# Retire only from authoritative merged-PR facts whose merge commit is reachable from the
# post-sync head. The helper plans every candidate before editing, and this function commits
# each manifest deletion with its allowlist deletion before the single integration push.
retire_spent_intent_diffs() { # $1 checkout dir, $2 owner/repo
  local wt="$1" repo="$2" output
  output=$(python3 "$_self_dir/retire_spent_intent_diffs.py" \
    --repo-root "$wt" --github-repo "$repo" --protected-ref HEAD 2>&1) || {
      echo "    WARN: $output"
      return 1
    }
  echo "    $output"
  git -C "$wt" diff --quiet -- migration/intent-diffs migration/intent-bounded-replay.allowlist \
    && return 0
  git -C "$wt" add -- migration/intent-diffs migration/intent-bounded-replay.allowlist
  git -C "$wt" commit -m "chore(migration): retire spent intent-diff manifests" >/dev/null 2>&1 \
    || { echo "    WARN: could not commit spent intent-diff retirement"; return 1; }
}

# Ensure a checkout's INTEGRATION_BRANCH is >= UPSTREAM_BRANCH (dev), retire any one-use
# intent manifests already landed in that integration history, and push the transaction.
# Forward-only (never rewrites integration); conflicts remain for sync_conflict.
ensure_integration_caught_up() { # $1 checkout dir, $2 owner/repo
  local wt="$1" repo="$2"
  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0
  [ "$INTEGRATION_BRANCH" = "$UPSTREAM_BRANCH" ] && return 0
  git -C "$wt" fetch origin "$INTEGRATION_BRANCH" "$UPSTREAM_BRANCH" -q 2>/dev/null || return 0
  git -C "$wt" rev-parse --verify "origin/$INTEGRATION_BRANCH" >/dev/null 2>&1 || return 0
  git -C "$wt" rev-parse --verify "origin/$UPSTREAM_BRANCH" >/dev/null 2>&1 || return 0
  local behind; behind=$(git -C "$wt" rev-list --count "origin/$INTEGRATION_BRANCH..origin/$UPSTREAM_BRANCH" 2>/dev/null || echo 0)
  restore_generated_workspace_scratch "$wt"
  git -C "$wt" checkout -q -B "$INTEGRATION_BRANCH" "origin/$INTEGRATION_BRANCH" 2>/dev/null \
    || { echo "    WARN: could not checkout $INTEGRATION_BRANCH — leaving for sync_scan"; return 0; }
  restore_generated_workspace_scratch "$wt"
  if [ "${behind:-0}" -gt 0 ]; then
    echo "  $INTEGRATION_BRANCH is $behind behind $UPSTREAM_BRANCH in $(basename "$wt") -> merging $UPSTREAM_BRANCH forward"
    if ! git -C "$wt" merge --no-edit "origin/$UPSTREAM_BRANCH" >/dev/null 2>&1; then
      git -C "$wt" merge --abort 2>/dev/null
      echo "    WARN: $UPSTREAM_BRANCH does not merge cleanly into $INTEGRATION_BRANCH — leaving for sync_conflict"
      return 0
    fi
  fi
  if ! retire_spent_intent_diffs "$wt" "$repo"; then
    git -C "$wt" reset --hard "origin/$INTEGRATION_BRANCH" -q 2>/dev/null
    echo "    WARN: integration sync not pushed because intent-diff retirement could not be proven"
    return 1
  fi
  local ahead; ahead=$(git -C "$wt" rev-list --count "origin/$INTEGRATION_BRANCH..HEAD" 2>/dev/null || echo 0)
  [ "${ahead:-0}" -eq 0 ] && return 0
  if git -C "$wt" push origin "HEAD:$INTEGRATION_BRANCH" >/dev/null 2>&1; then
    echo "    synced + pushed: $INTEGRATION_BRANCH -> $(git -C "$wt" rev-parse --short HEAD)"
  else
    echo "    WARN: sync ok but push failed (perm/race) — leaving for sync_scan"
  fi
}
