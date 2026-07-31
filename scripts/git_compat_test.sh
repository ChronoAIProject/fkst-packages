#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp -d "${TMPDIR:-/tmp}/fkst-git-compat.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

remote="$tmp/remote.git"
source_repo="$tmp/source"
client="$tmp/client"

git init -q --bare "$remote"
git init -q "$source_repo"
git -C "$source_repo" config user.name "fkst git compatibility test"
git -C "$source_repo" config user.email "fkst-git-compat@example.invalid"
printf '%s\n' "compatibility fixture" > "$source_repo/fixture.txt"
git -C "$source_repo" add fixture.txt
git -C "$source_repo" commit -q -m "Create compatibility fixture"
expected_oid="$(git -C "$source_repo" rev-parse --verify 'HEAD^{commit}')"
git -C "$source_repo" remote add origin "$remote"
git -C "$source_repo" push -q origin HEAD:refs/pull/7/head

git init -q "$client"
git -C "$client" remote add origin "$remote"
(
  cd "$client"
  git fetch --no-write-fetch-head origin '+refs/pull/7/head:refs/fkst/pr/7'
  actual_oid="$(git rev-parse --verify 'refs/fkst/pr/7^{commit}')"
  test "$actual_oid" = "$expected_oid"
  test ! -e .git/FETCH_HEAD
)

echo "OK: forge.git PR-head fetch contract works with $(git --version)"
