#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lua_bin="${LUA_BIN:-lua}"
if ! command -v "$lua_bin" >/dev/null 2>&1; then
  echo "error: git compatibility test requires $lua_bin" >&2
  exit 1
fi

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
  EXPECTED_OID="$expected_oid" \
    LUA_PATH="$root/libraries/?.lua;$root/libraries/?/init.lua;;" \
    "$lua_bin" - <<'LUA'
local argv_render = require("forge.argv")
local git = require("forge.git")

local function run_argv(opts)
  local process = assert(io.popen(argv_render.render(opts.argv) .. " 2>&1", "r"))
  local output = process:read("*a")
  local ok, _, status = process:close()
  return {
    stdout = output,
    stderr = ok and "" or output,
    exit_code = ok and 0 or (tonumber(status) or 1),
  }
end

local result = git.new(run_argv).fetch_pr_head_oid("origin", 7, 60)
assert(result.exit_code == 0, "fetch_pr_head_oid failed: " .. tostring(result.stderr))
local actual_oid = tostring(result.stdout or ""):match("^%s*(%x+)%s*$")
assert(actual_oid == os.getenv("EXPECTED_OID"), "fetch_pr_head_oid returned the wrong OID")
LUA
  test ! -e .git/FETCH_HEAD
)

echo "OK: forge.git PR-head fetch contract works with $(git --version)"
