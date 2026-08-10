#!/usr/bin/env bash
# Changed-path local verification for implementation/fix worktrees.
#
# Scope is derived from the worktree's OWN uncommitted edits: the implement/fix
# codex makes its changes and runs local verification BEFORE the change is
# committed, so `git diff HEAD` + untracked files are exactly the codex's
# changes. This needs no base branch and no env var, so it is robust across
# branch topologies and across spawned-codex environments that do not carry
# FKST_DEVLOOP_INTEGRATION_BRANCH. CI runs the full `scripts/run.sh test` (all
# packages + composed conformance) as the comprehensive gate; this is fast local
# feedback only. Selection consumes the engine's declared dependency graph and
# fails closed to the full suite whenever that graph or a changed path cannot be
# classified.

test_affected_changed_paths() {
  {
    git -C "$ROOT" diff --no-renames --name-only HEAD
    git -C "$ROOT" ls-files --others --exclude-standard
  } | sed '/^$/d' | LC_ALL=C sort -u
}

test_affected_run_test() {
  local result_file exit_code merge_code=0
  result_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected-result.XXXXXX")" || {
    local_iteration_result_fail "INFRASTRUCTURE"
    return 1
  }
  if [ -n "${FKST_TEST_AFFECTED_RUNNER:-}" ]; then
    if FKST_LOCAL_ITERATION_RESULT_FILE="$result_file" "$FKST_TEST_AFFECTED_RUNNER" "$@"; then
      exit_code=0
    else
      exit_code=$?
    fi
  elif FKST_LOCAL_ITERATION_RESULT_FILE="$result_file" "$ROOT/scripts/run.sh" "$@"; then
    exit_code=0
  else
    exit_code=$?
  fi
  local_iteration_result_merge_file "$result_file" "$exit_code" || merge_code=$?
  rm -f "$result_file"
  [ "$merge_code" -eq 0 ] || return 1
  return "$exit_code"
}

cmd_test_affected() {
  local changed_file deps_file selected_file full=0 packages="" path status=0
  changed_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected-paths.XXXXXX")" || {
    local_iteration_result_fail "INFRASTRUCTURE"
    return 1
  }
  deps_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected-deps.XXXXXX")" || {
    rm -f "$changed_file"
    local_iteration_result_fail "INFRASTRUCTURE"
    return 1
  }
  selected_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected-selected.XXXXXX")" || {
    rm -f "$changed_file" "$deps_file"
    local_iteration_result_fail "INFRASTRUCTURE"
    return 1
  }
  test_affected_changed_paths > "$changed_file"

  resolve_bin
  ensure_fresh_bin
  if ! "$BIN" deps --project-root "$ROOT" --json > "$deps_file"; then
    full=1
  elif ! python3 -B "$ROOT/scripts/test_selection.py" \
      --project-root "$ROOT" \
      --changed-paths "$changed_file" \
      --deps-json "$deps_file" > "$selected_file"; then
    full=1
  else
    while IFS= read -r path || [ -n "$path" ]; do
      [ -n "$path" ] || continue
      if [ "$path" = "FULL" ]; then
        full=1
        continue
      fi
      case "$path" in
        *[!A-Za-z0-9_-]*|"") full=1 ;;
        *) packages="$packages $path" ;;
      esac
    done < "$selected_file"
  fi
  rm -f "$changed_file" "$deps_file" "$selected_file"

  if [ "$full" -eq 1 ]; then
    if test_affected_run_test test; then
      status=0
    else
      status=$?
    fi
  elif [ -z "${packages# }" ]; then
    if test_affected_run_test test --repo-only; then
      status=0
    else
      status=$?
    fi
  else
    if ! test_affected_run_test test $packages; then
      status=1
    fi
  fi
  return "$status"
}
