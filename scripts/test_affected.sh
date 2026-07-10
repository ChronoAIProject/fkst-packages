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

test_affected_is_broad_path() {
  local path="$1"
  case "$path" in
    .claude/skills/dogfood-github-devloop/*) return 0 ;;
    scripts/*|.github/*) return 0 ;;
  esac
  test_affected_is_root_config "$path"
}

test_affected_manifest_lib_deps() {
  local manifest="$1"
  [ -f "$manifest" ] || return 0
  awk '
    /^\[/ {
      in_lib_deps = ($0 == "[lib_deps]")
      next
    }
    in_lib_deps && /^[[:space:]]*libraries[[:space:]]*=/ {
      line = $0
      while (line !~ /\]/ && (getline more) > 0) {
        line = line " " more
      }
      while (match(line, /"[^"]+"/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$manifest"
}

test_affected_word_set_contains() {
  local words="$1" needle="$2"
  case " $words " in
    *" $needle "*) return 0 ;;
    *) return 1 ;;
  esac
}

test_affected_word_set_intersects_lib_deps() {
  local libs="$1" manifest="$2" dep
  while IFS= read -r dep || [ -n "$dep" ]; do
    [ -n "$dep" ] || continue
    if test_affected_word_set_contains "$libs" "$dep"; then
      return 0
    fi
  done < <(test_affected_manifest_lib_deps "$manifest")
  return 1
}

test_affected_expand_library_closure() {
  local libs="$1" changed=1 manifest lib
  while [ "$changed" -eq 1 ]; do
    changed=0
    for manifest in "$ROOT"/libraries/*/fkst.toml; do
      [ -f "$manifest" ] || continue
      lib="${manifest%/fkst.toml}"
      lib="${lib##*/}"
      if test_affected_word_set_contains "$libs" "$lib"; then
        continue
      fi
      if test_affected_word_set_intersects_lib_deps "$libs" "$manifest"; then
        libs="$libs $lib"
        changed=1
      fi
    done
  done
  printf '%s\n' "$libs"
}

test_affected_add_library_dependents() {
  local seed_libs="$1" packages="$2" affected_libs manifest package
  [ -n "${seed_libs# }" ] || {
    printf '%s\n' "$packages"
    return 0
  }
  affected_libs="$(test_affected_expand_library_closure "$seed_libs")"
  for manifest in "$ROOT"/packages/*/fkst.toml; do
    [ -f "$manifest" ] || continue
    package="${manifest%/fkst.toml}"
    package="${package##*/}"
    if test_affected_word_set_contains "$packages" "$package"; then
      continue
    fi
    if test_affected_word_set_intersects_lib_deps "$affected_libs" "$manifest"; then
      packages="$packages $package"
    fi
  done
  printf '%s\n' "$packages"
}

test_affected_run_test() {
  if [ -n "${FKST_TEST_AFFECTED_RUNNER:-}" ]; then
    "$FKST_TEST_AFFECTED_RUNNER" "$@"
    return $?
  fi
  "$ROOT/scripts/run.sh" "$@"
}

cmd_test_affected() {
  local changed_file full=0 packages="" changed_libs="" path package lib status=0
  changed_file="$(mktemp "${TMPDIR:-/tmp}/fkst-test-affected.XXXXXX")"
  test_affected_changed_paths > "$changed_file"

  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    if test_affected_is_broad_path "$path"; then
      full=1
    fi
    case "$path" in
      packages/*/*)
        package="${path#packages/}"
        package="${package%%/*}"
        case " $packages " in
          *" $package "*) ;;
          *) packages="$packages $package" ;;
        esac
        ;;
      libraries/*/*)
        lib="${path#libraries/}"
        lib="${lib%%/*}"
        case " $changed_libs " in
          *" $lib "*) ;;
          *) changed_libs="$changed_libs $lib" ;;
        esac
        ;;
    esac
  done < "$changed_file"
  rm -f "$changed_file"

  packages="$(test_affected_add_library_dependents "$changed_libs" "$packages")"

  if [ "$full" -eq 1 ] || [ -z "${packages# }" ]; then
    test_affected_run_test test
    return $?
  fi
  for package in $packages; do
    if ! test_affected_run_test test "$package"; then
      status=1
    fi
  done
  return "$status"
}
