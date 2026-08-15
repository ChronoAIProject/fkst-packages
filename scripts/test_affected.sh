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
# feedback only. When nothing scoped is detected (no uncommitted package edits),
# it falls back to the full suite.

test_affected_changed_paths() {
  {
    git -C "$ROOT" diff --name-only HEAD
    git -C "$ROOT" ls-files --others --exclude-standard
  } | sed '/^$/d' | LC_ALL=C sort -u
}

test_affected_is_root_config() {
  local path="$1"
  case "$path" in
    */*) return 1 ;;
    Cargo.toml|Cargo.lock|fkst.workspace.toml|fkst.lock|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock|pyproject.toml|poetry.lock|requirements.txt|codecov.yml)
      return 0
      ;;
    *.toml|*.yml|*.yaml|*.lock|*.config.js|*.config.ts|*.config.cjs|*.config.mjs)
      return 0
      ;;
    *) return 1 ;;
  esac
}

test_affected_requires_full_suite() {
  local path="$1"
  case "$path" in
    scripts/*|.github/*) return 0 ;;
    libraries/*/*|packages/*/*) return 1 ;;
  esac
  test_affected_is_root_config "$path" && return 0
  return 0
}

test_affected_run_test() {
  local result_file output_file exit_code merge_code=0
  result_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected-result.XXXXXX")" || {
    local_iteration_result_fail "INFRASTRUCTURE"
    return 1
  }
  output_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected-output.XXXXXX")" || {
    rm -f "$result_file"
    local_iteration_result_fail "INFRASTRUCTURE"
    return 1
  }
  if [ -n "${FKST_TEST_AFFECTED_RUNNER:-}" ]; then
    if FKST_LOCAL_ITERATION_RESULT_FILE="$result_file" "$FKST_TEST_AFFECTED_RUNNER" "$@" > "$output_file"; then
      exit_code=0
    else
      exit_code=$?
    fi
  elif FKST_LOCAL_ITERATION_RESULT_FILE="$result_file" "$ROOT/scripts/run.sh" "$@" > "$output_file"; then
    exit_code=0
  else
    exit_code=$?
  fi
  if [ "$exit_code" -eq 0 ]; then
    cat "$output_file"
  else
    cat "$output_file" >&2
  fi
  local_iteration_result_merge_file "$result_file" "$exit_code" || merge_code=$?
  rm -f "$result_file" "$output_file"
  [ "$merge_code" -eq 0 ] || return 1
  return "$exit_code"
}

cmd_test_affected() {
  local changed_file scoped_file resolved_file full=0 path package status=0
  local -a packages=()
  changed_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected.XXXXXX")"
  scoped_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected-scoped.XXXXXX")"
  resolved_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected-resolved.XXXXXX")"
  test_affected_changed_paths > "$changed_file"

  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    if test_affected_requires_full_suite "$path"; then
      full=1
    else
      printf '%s\n' "$path" >> "$scoped_file"
    fi
  done < "$changed_file"

  if [ "$full" -eq 0 ] && [ -s "$scoped_file" ]; then
    if ! python3 "$ROOT/scripts/test_affected.py" "$ROOT" "$scoped_file" > "$resolved_file"; then
      full=1
    else
      while IFS= read -r package || [ -n "$package" ]; do
        [ -n "$package" ] || continue
        packages+=("$package")
      done < "$resolved_file"
    fi
  fi
  rm -f "$changed_file" "$scoped_file" "$resolved_file"

  if [ "$full" -eq 1 ] || [ "${#packages[@]}" -eq 0 ]; then
    if test_affected_run_test test; then
      status=0
    else
      status=$?
    fi
  else
    if test_affected_run_test test "${packages[@]}"; then
      status=0
    else
      status=1
    fi
  fi
  return "$status"
}
