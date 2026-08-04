local t = fkst.test

local system_path = "/usr/bin:/bin"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function command_output(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok = handle:close()
  return output, ok ~= false and ok ~= nil
end

local function read_command(command)
  local output, ok = command_output(command)
  if not ok then
    error("consensus terminal-result fixture command failed: " .. command .. "\n" .. output)
  end
  return output
end

local function write_file(path, body)
  file.write(path, body)
end

local function framework_bin()
  local bin = os.getenv("BIN") or ""
  if bin == "" then
    error("consensus terminal-result fixture requires BIN")
  end
  return bin
end

local function repo_root()
  return read_command("git rev-parse --show-toplevel"):gsub("%s+$", "")
end

local function count_files(path)
  local output = read_command("find " .. shell_quote(path) .. " -type f | wc -l")
  return assert(tonumber(output:match("%d+")))
end

local function remove_fixture(root)
  local prefix = "/tmp/fkst-consensus-terminal-adoption."
  if root:sub(1, #prefix) ~= prefix then
    error("refusing to remove unexpected fixture root: " .. tostring(root))
  end
  read_command("rm -rf " .. shell_quote(root))
end

local function write_fake_codex(root)
  read_command("mkdir -p " .. shell_quote(root .. "/bin"))
  read_command("mkdir -p " .. shell_quote(root .. "/codex-started"))
  write_file(root .. "/bin/codex", [[#!/bin/sh
set -eu
: > "$FKST_FIXTURE_ROOT/codex-started/$$"
printf '⟦FKST:VERDICT⟧ approve\n⟦FKST:REPLY⟧ The terminal result was adopted.\n'
]])
  read_command("chmod +x " .. shell_quote(root .. "/bin/codex"))
end

local function write_project(root, source)
  local package_root = root .. "/packages/consensus-terminal-fixture"
  read_command("mkdir -p " .. shell_quote(package_root .. "/departments/reach"))
  read_command("cp -R " .. shell_quote(source .. "/libraries") .. " " .. shell_quote(root .. "/libraries"))

  write_file(root .. "/fkst.workspace.toml", [[
[workspace]
units = ["packages/*", "libraries/*"]
packages = ["packages/*"]
libraries = ["libraries/*"]

[registries]
workspace = "workspace"
]])
  write_file(package_root .. "/fkst.toml", [[
kind = "package"
name = "consensus-terminal-fixture"

[code]
root = "."

[lib_deps]
libraries = ["consensus"]
]])
  write_file(package_root .. "/departments/reach/main.lua", [[
local consensus = require("consensus")

local M = {}

M.spec = {
  consumes = { "proposal" },
  produces = { "done" },
  stall_window = "30s",
}

function M.pipeline(event)
  local proposal = assert(event and event.payload)
  if proposal.fail_before_memo == true then
    local real_cache_set = cache_set
    cache_set = function(key, value)
      if tostring(key):match("^consensus/result%-memo/") then
        error("synthetic owner loss before result memo")
      end
      return real_cache_set(key, value)
    end
  end

  local result = consensus.reach(proposal, { invocation_id = "stable-invocation-42" })
  assert(result and result.status == "reached")
  raise("done", {
    schema = "consensus-terminal-fixture.done.v1",
    decision = result.decision,
  })
end

return M
]])
  return package_root
end

local function event_json(dedup_key, fail_before_memo)
  return string.format([[
{"queue":"proposal","payload":{"schema":"consensus.proposal.v1","proposal_id":"delivery-local-proposal","title":"Adopt completed consensus seats","body":"Replay one consensus invocation after its delivery owner exits.","context":"The replay must consume terminal child results without replacement spawns.","angles":["teleology","parsimony","fidelity"],"dedup_key":"%s","source_ref":{"kind":"external","ref":"fixture/repo#proposal/42"},"fail_before_memo":%s}}
]], dedup_key, tostring(fail_before_memo))
end

local function run_reach(bin, root, package_root, event)
  local command = table.concat({
    "PATH=" .. shell_quote(root .. "/bin:" .. system_path),
    "HOME=" .. shell_quote(os.getenv("HOME") or "/tmp"),
    "FKST_RUNTIME_ROOT=" .. shell_quote(root .. "/runtime"),
    "FKST_RUNTIME_LOG_DIR=" .. shell_quote(root .. "/runtime/logs"),
    "FKST_RATE_POOL_ROOT=" .. shell_quote(root .. "/runtime/rate-pools"),
    "FKST_FIXTURE_ROOT=" .. shell_quote(root),
    shell_quote(bin),
    "run", shell_quote(package_root .. "/departments/reach/main.lua"),
    "--project-root", shell_quote(root),
    "--package-root", shell_quote(package_root),
    "--owner-namespace", "consensus-terminal-fixture",
    "--event", shell_quote(event),
  }, " ")
  return command_output(command)
end

return {
  test_fresh_owner_adopts_terminal_results_after_memo_boundary_failure = function()
    local root = read_command("mktemp -d "
      .. shell_quote("/tmp/fkst-consensus-terminal-adoption.XXXXXX")):gsub("%s+$", "")
    local ok, err = pcall(function()
      local bin = framework_bin()
      write_fake_codex(root)
      local package_root = write_project(root, repo_root())
      local first_event = event_json("delivery-a", true)
      local replay_event = event_json("delivery-b", false)

      local first_output, first_ok = run_reach(bin, root, package_root, first_event)
      t.eq(first_ok, false)
      t.is_true(first_output:find("synthetic owner loss before result memo", 1, true) ~= nil)
      t.eq(count_files(root .. "/codex-started"), 3)

      local replay_output, replay_ok = run_reach(bin, root, package_root, replay_event)
      t.eq(replay_ok, true, replay_output)
      t.is_true(replay_output:find("RAISED:", 1, true) ~= nil)
      t.eq(count_files(root .. "/codex-started"), 3)
    end)

    local cleanup_ok, cleanup_err = pcall(remove_fixture, root)
    if not ok then
      error(err)
    end
    if not cleanup_ok then
      error(cleanup_err)
    end
  end,
}
