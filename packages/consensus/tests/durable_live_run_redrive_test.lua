local t = fkst.test

local redrive_count = 13
local wait_seconds = 30
local system_path = "/usr/bin:/bin"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local command_output = require("testkit_internal.testing").command_output

local function read_command(command)
  local output, ok = command_output(command)
  if not ok then
    error("consensus durable live-run fixture command failed: " .. tostring(command) .. "\n" .. tostring(output))
  end
  return output
end

local function run_command(command)
  read_command(command)
end

local function write_file(path, body)
  file.write(path, body)
end

local function read_optional(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local body = handle:read("*a")
  handle:close()
  return body
end

local function wait_until(description, details, probe)
  local last = nil
  for _ = 1, wait_seconds * 10 do
    local value, detail = probe()
    last = detail or last
    if value ~= nil and value ~= false then
      return value
    end
    os.execute("sleep 0.1")
  end
  local fixture_details = details and details() or ""
  error("timed out waiting for " .. description
    .. (last and ("\n" .. tostring(last)) or "")
    .. (fixture_details ~= "" and ("\nfixture logs:\n" .. fixture_details) or ""))
end

local function process_alive(pid)
  local _, ok = command_output("kill -0 " .. tostring(pid))
  return ok
end

local function stop_process(pid)
  if not process_alive(pid) then
    return
  end
  command_output("kill -TERM " .. tostring(pid))
  wait_until("fixture supervise process to exit", nil, function()
    return not process_alive(pid)
  end)
end

local function framework_bin()
  local bin = os.getenv("BIN") or ""
  if bin == "" then
    error("consensus durable live-run fixture requires BIN")
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

local function fixture_logs(root)
  local output = command_output("for path in " .. shell_quote(root .. "/supervise.stdout") .. " "
    .. shell_quote(root .. "/supervise.stderr") .. "; do"
    .. " [ -f \"$path\" ] || continue;"
    .. " echo FILE:$path; tail -120 \"$path\";"
    .. " done")
  return output
end

local function remove_fixture(root)
  local prefix = "/tmp/fkst-consensus-durable-live-run."
  if root:sub(1, #prefix) ~= prefix then
    error("refusing to remove unexpected fixture root: " .. tostring(root))
  end
  run_command("rm -rf " .. shell_quote(root))
end

local function write_fake_codex(root)
  run_command("mkdir -p " .. shell_quote(root .. "/bin"))
  run_command("mkdir -p " .. shell_quote(root .. "/codex-started"))
  run_command("mkdir -p " .. shell_quote(root .. "/codex-running"))
  write_file(root .. "/bin/codex", [[#!/bin/sh
set -eu
started="$FKST_FIXTURE_ROOT/codex-started/$$"
running="$FKST_FIXTURE_ROOT/codex-running/$$"
: > "$started"
: > "$running"
cleanup() {
  rm -f "$running"
}
trap cleanup EXIT HUP INT TERM
while [ ! -f "$FKST_FIXTURE_ROOT/release-codex" ]; do
  sleep 0.05
done
printf '⟦FKST:VERDICT⟧ approve\n⟦FKST:REPLY⟧ The durable delivery behavior is correct.\n'
]])
  run_command("chmod +x " .. shell_quote(root .. "/bin/codex"))
end

local function write_project(root, source)
  local package_root = root .. "/packages/consensus-durable-fixture"
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/source"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/reach"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/raisers"))
  run_command("mkdir -p " .. shell_quote(root .. "/triggers"))
  run_command("mkdir -p " .. shell_quote(root .. "/redrive-ready"))
  run_command("cp -R " .. shell_quote(source .. "/libraries") .. " " .. shell_quote(root .. "/libraries"))

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
name = "consensus-durable-fixture"

[code]
root = "."

[lib_deps]
libraries = ["consensus"]
]])
  write_file(package_root .. "/departments/source/main.lua", [[
local M = {}

M.spec = {
  consumes = { "activate" },
  produces = { "proposal" },
  stall_window = "5s",
}

function M.pipeline(event)
  local path = assert(event and event.payload and event.payload.path)
  local delivery_dedup = assert(path:match("([^/]+)%.trigger$"))
  raise("proposal", {
    schema = "consensus.proposal.v1",
    proposal_id = "durable-proposal-42",
    title = "Verify durable live-run redrive admission",
    body = "Treat a duplicate activation for a live single-flight run as an acknowledged no-op.",
    content_fetch = "printf durable-live-run-fixture",
    context = "The original run must complete and apply its result after duplicate redrives are acknowledged.",
    angles = { "teleology", "parsimony", "fidelity" },
    dedup_key = delivery_dedup,
    source_ref = { kind = "external", ref = "fixture/repo#proposal/42" },
  })
end

return M
]])
  write_file(package_root .. "/departments/reach/main.lua", [[
local consensus = require("consensus")

local M = {}

M.spec = {
  consumes = { "proposal" },
  produces = {},
  stall_window = "30s",
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}

local function root()
  return assert(os.getenv("FKST_FIXTURE_ROOT"))
end

local function exists(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return false
  end
  handle:close()
  return true
end

local function write(path, body)
  local handle = assert(io.open(path, "w"))
  handle:write(body)
  handle:close()
end

function M.pipeline(event)
  local proposal = assert(event and event.payload)
  local result = consensus.reach(proposal, { invocation_id = proposal.proposal_id })
  if result == nil then
    write(root() .. "/redrive-ready/" .. proposal.dedup_key, "ready\n")
    while not exists(root() .. "/ack-redrives") do
      os.execute("sleep 0.05")
    end
    return
  end
  write(root() .. "/result-applied", table.concat({
    "delivery=" .. tostring(proposal.dedup_key),
    "status=" .. tostring(result.status),
    "decision=" .. tostring(result.decision),
    "",
  }, "\n"))
end

return M
]])
  write_file(package_root .. "/raisers/activation.lua", string.format([[
return { type = "file_watch", glob = %q, produces = "activate" }
]], root .. "/triggers/*.trigger"))
  return package_root
end

local function start_supervise(bin, root, package_root, runtime_root, durable_root)
  local command = table.concat({
    "PATH=" .. shell_quote(root .. "/bin:" .. system_path),
    "HOME=" .. shell_quote(os.getenv("HOME") or "/tmp"),
    "FKST_RUNTIME_ROOT=" .. shell_quote(runtime_root),
    "FKST_RUNTIME_LOG_DIR=" .. shell_quote(runtime_root .. "/logs"),
    "FKST_DURABLE_ROOT=" .. shell_quote(durable_root),
    "FKST_RATE_POOL_ROOT=" .. shell_quote(durable_root .. "/rate-pools"),
    "FKST_FIXTURE_ROOT=" .. shell_quote(root),
    "FKST_MAX_IN_FLIGHT_PER_DEPT=16",
    shell_quote(bin),
    "supervise",
    "--project-root", shell_quote(root),
    "--package-root", shell_quote(package_root),
    "--framework-bin", shell_quote(bin),
    ">" .. shell_quote(root .. "/supervise.stdout"),
    "2>" .. shell_quote(root .. "/supervise.stderr"),
    "& printf '%s\\n' \"$!\"",
  }, " ")
  local output = read_command(command)
  local pid = tonumber(output:match("(%d+)"))
  if pid == nil then
    error("consensus durable live-run fixture did not return a supervise pid: " .. tostring(output))
  end
  return pid
end

local function observe(bin, durable_root)
  local output = read_command(shell_quote(bin) .. " observe --durable-root "
    .. shell_quote(durable_root) .. " --json")
  return json.decode(output), output
end

local function proposal_deliveries(snapshot)
  local deliveries = {}
  for _, delivery in ipairs(snapshot.deliveries or {}) do
    if delivery.queue == "consensus-durable-fixture.proposal"
      and delivery.dept == "consensus-durable-fixture.reach" then
      table.insert(deliveries, delivery)
    end
  end
  return deliveries
end

local function redrive_deliveries(snapshot)
  local deliveries = {}
  for _, delivery in ipairs(proposal_deliveries(snapshot)) do
    local dedup_key = delivery.payload and delivery.payload.dedup_key or ""
    if tostring(dedup_key):match("^redrive%-%d%d$") then
      table.insert(deliveries, delivery)
    end
  end
  return deliveries
end

local function assert_no_dead_letters(snapshot)
  t.eq(#(snapshot.dead_letters or {}), 0)
end

local function release_fixture(root)
  pcall(write_file, root .. "/ack-redrives", "ack\n")
  pcall(write_file, root .. "/release-codex", "release\n")
end

return {
  test_live_consensus_run_acknowledges_durable_redrives_without_attempts_or_dead_letters = function()
    local root = read_command("mktemp -d "
      .. shell_quote("/tmp/fkst-consensus-durable-live-run.XXXXXX")):gsub("%s+$", "")
    local active_pid = nil
    local ok, err = pcall(function()
      local bin = framework_bin()
      local durable_root = root .. "/durable"
      write_fake_codex(root)
      local package_root = write_project(root, repo_root())
      active_pid = start_supervise(bin, root, package_root, root .. "/runtime", durable_root)

      write_file(root .. "/triggers/initial.trigger", "initial\n")
      wait_until("the original consensus codex workers to start", function()
        return fixture_logs(root)
      end, function()
        local started = count_files(root .. "/codex-started")
        if started == 3 then
          return true
        end
        return nil, "started codex workers=" .. tostring(started)
      end)

      for index = 1, redrive_count do
        local name = string.format("redrive-%02d", index)
        write_file(root .. "/triggers/" .. name .. ".trigger", name .. "\n")
      end

      wait_until("all durable redrives to reach acknowledged live-run no-op", function()
        return fixture_logs(root)
      end, function()
        local ready = count_files(root .. "/redrive-ready")
        if ready ~= redrive_count then
          return nil, "completed live-run redrives=" .. tostring(ready)
        end
        local snapshot, raw = observe(bin, durable_root)
        assert_no_dead_letters(snapshot)
        local redrives = redrive_deliveries(snapshot)
        local in_flight = 0
        for _, delivery in ipairs(redrives) do
          if delivery.attempt ~= 0 then
            error("durable live-run redrive consumed an attempt: " .. raw)
          end
          if delivery.status == "in-flight" then
            in_flight = in_flight + 1
          end
        end
        if #redrives == redrive_count and in_flight == redrive_count then
          return snapshot
        end
        return nil, raw
      end)
      t.eq(count_files(root .. "/codex-started"), 3)

      write_file(root .. "/ack-redrives", "ack\n")
      wait_until("durable redrives to be acknowledged", function()
        return fixture_logs(root)
      end, function()
        local snapshot, raw = observe(bin, durable_root)
        assert_no_dead_letters(snapshot)
        if #redrive_deliveries(snapshot) == 0 then
          return snapshot
        end
        return nil, raw
      end)
      t.eq(count_files(root .. "/codex-started"), 3)

      write_file(root .. "/release-codex", "release\n")
      local applied = wait_until("the original consensus result to be applied", function()
        return fixture_logs(root)
      end, function()
        return read_optional(root .. "/result-applied")
      end)
      t.is_true(applied:find("delivery=initial", 1, true) ~= nil)
      t.is_true(applied:find("status=reached", 1, true) ~= nil)
      t.is_true(applied:find("decision=approve", 1, true) ~= nil)

      wait_until("the original durable delivery to be acknowledged", function()
        return fixture_logs(root)
      end, function()
        local snapshot, raw = observe(bin, durable_root)
        assert_no_dead_letters(snapshot)
        if #proposal_deliveries(snapshot) == 0 then
          return snapshot
        end
        return nil, raw
      end)
      t.eq(count_files(root .. "/codex-started"), 3)
    end)

    release_fixture(root)
    if active_pid ~= nil then
      pcall(stop_process, active_pid)
    end
    pcall(function()
      wait_until("fixture codex processes to exit", nil, function()
        return count_files(root .. "/codex-running") == 0
      end)
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
