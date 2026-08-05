local capacity = require("core.intake_capacity")
local t = fkst.test

local owner = "fkst-test-bot"
local wait_seconds = 45
local system_path = "/usr/bin:/bin"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function command_output(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok, _, status = handle:close()
  return output, ok ~= false and ok ~= nil, tonumber(status) or (ok and 0 or 1)
end

local function read_command(command)
  local output, ok = command_output(command)
  if not ok then
    error("intake capacity production harness command failed: " .. tostring(command) .. "\n" .. tostring(output))
  end
  return output
end

local function run_command(command)
  read_command(command)
end

local function repo_root()
  return read_command("pwd"):gsub("%s+$", "")
end

local function framework_bin()
  local bin = os.getenv("BIN") or ""
  if bin == "" then
    error("intake capacity production harness requires BIN")
  end
  return bin
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
  local logs = details and details() or ""
  error("timed out waiting for " .. description
    .. (last and ("\n" .. tostring(last)) or "")
    .. (logs ~= "" and ("\nfixture logs:\n" .. logs) or ""))
end

local function process_alive(pid)
  local _, ok = command_output("kill -0 " .. tostring(pid))
  return ok
end

local function stop_process(pid, signal)
  if not process_alive(pid) then
    return
  end
  command_output("kill -" .. tostring(signal or "TERM") .. " " .. tostring(pid))
  wait_until("supervise process " .. tostring(pid) .. " to exit", nil, function()
    return not process_alive(pid)
  end)
end

local function remove_fixture(root)
  local prefix = "/tmp/fkst-intake-capacity-production."
  if root:sub(1, #prefix) ~= prefix then
    error("refusing to remove unexpected fixture root: " .. tostring(root))
  end
  run_command("rm -rf " .. shell_quote(root))
end

local function write_proxy_package(root)
  local package_root = root .. "/packages/github-proxy"
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/source"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/comment_sink"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/issue_create_sink"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/raisers"))
  write_file(package_root .. "/fkst.toml", [[
kind = "package"
name = "github-proxy"

[code]
root = "."
]])
  write_file(package_root .. "/departments/source/main.lua", [[
local M = {}

M.spec = {
  consumes = { "seed" },
  produces = { "github_entity_changed", "github_issue_observed" },
  stall_window = "5s",
}

function M.pipeline(_event)
  local repo = assert(os.getenv("FKST_GITHUB_REPO"))
  local number = assert(tonumber(os.getenv("FKST_CAPACITY_ISSUE_NUMBER")))
  local updated_at = assert(os.getenv("FKST_CAPACITY_UPDATED_AT"))
  raise("github_entity_changed", {
    schema = "github-proxy.v1",
    type = "issue",
    repo = repo,
    number = number,
    state = "OPEN",
    labels = {},
    updated_at = updated_at,
    dedup_key = repo .. "#issue#" .. tostring(number) .. "@" .. updated_at,
    source_ref = { kind = "external", ref = repo .. "#issue/" .. tostring(number) },
  })
end

return M
]])
  write_file(package_root .. "/departments/comment_sink/main.lua", [[
local M = {}

M.spec = {
  consumes = { "github_issue_comment_request" },
  produces = {},
  published_seam = { "github_issue_comment_request" },
  stall_window = "5s",
}

function M.pipeline(_event)
end

return M
]])
  write_file(package_root .. "/departments/issue_create_sink/main.lua", [[
local M = {}

M.spec = {
  consumes = { "github_issue_create_request" },
  produces = {},
  published_seam = { "github_issue_create_request" },
  stall_window = "5s",
}

function M.pipeline(_event)
end

return M
]])
  write_file(package_root .. "/raisers/source.lua", string.format([[
return {
  type = "file_watch",
  glob = %q,
  produces = "seed",
}
]], root .. "/trigger/input.trigger"))
  return package_root
end

local function capacity_fixture_dependencies()
  return [[
local base_ids = require("devloop.base_ids")
local claims = require("devloop.claims")
local commands = require("devloop.commands")
local config = require("devloop.config")
local devloop_base = require("devloop.base")
local marker_builders = require("devloop.markers.builders")
local capacity = require("core.intake_capacity")
local core = require("core")

local M = {}

local function root()
  return assert(os.getenv("FKST_CAPACITY_CASE_ROOT"))
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

local function write(path, body)
  local handle = assert(io.open(path, "w"))
  handle:write(body)
  handle:close()
end

local function owner_path(number)
  return root() .. "/issues/" .. tostring(number) .. ".owner"
end

local function issue(number)
  local body = assert(read_optional(root() .. "/issues/" .. tostring(number) .. ".fact"), "missing fixture issue")
  local state, decision, dev_state = body:match("^([^\n]*)\n([^\n]*)\n([^\n]*)")
  local configured_owner = devloop_base.strip_bot_login_suffix(assert(os.getenv("FKST_GITHUB_BOT_LOGIN")))
  local current_owner = tostring(read_optional(owner_path(number)) or ""):gsub("%s+$", "")
  local proposal_id = base_ids.proposal_id(assert(os.getenv("FKST_GITHUB_REPO")), number)
  local comments = {}
  if decision ~= nil and decision ~= "" then
    table.insert(comments, {
      body = marker_builders.intake_decision_marker(
        proposal_id,
        decision,
        "intake/" .. proposal_id .. "/fixture",
        "standard"
      ),
      author_login = configured_owner,
      created_at = "2026-07-16T00:00:00Z",
    })
  end
  if dev_state ~= nil and dev_state ~= "" then
    table.insert(comments, {
      body = core.state_marker(proposal_id, dev_state, proposal_id .. "/fixture"),
      author_login = configured_owner,
      created_at = "2026-07-16T00:00:01Z",
    })
  end
  return {
    number = tonumber(number),
    title = "Fixture issue " .. tostring(number),
    body = "Production-shaped intake capacity fixture",
    state = state,
    labels = {},
    comments = comments,
    assignees = current_owner ~= "" and { current_owner } or {},
    author_login = configured_owner,
    updated_at = assert(os.getenv("FKST_CAPACITY_UPDATED_AT")),
  }
end

local function issue_numbers()
  local result = {}
  for value in tostring(os.getenv("FKST_CAPACITY_ISSUES") or ""):gmatch("[^,]+") do
    table.insert(result, assert(tonumber(value)))
  end
  return result
end

local function all_barrier_peers_ready(peers)
  for peer in tostring(peers or ""):gmatch("[^,]+") do
    if read_optional(root() .. "/barrier/" .. peer .. ".ready") == nil then
      return false
    end
  end
  return true
end

local function wait_at_push_barrier()
  local peers = os.getenv("FKST_CAPACITY_BARRIER_PEERS") or ""
  if peers == "" then
    return
  end
  local runtime_id = assert(os.getenv("FKST_CAPACITY_RUNTIME_ID"))
  write(root() .. "/barrier/" .. runtime_id .. ".ready", "ready\n")
  local deadline = os.time() + 15
  while not all_barrier_peers_ready(peers) do
    if os.time() >= deadline then
      error("capacity fixture push barrier timed out")
    end
    os.execute("sleep 0.05")
  end
end

function M.new()
  local adapter_commands = setmetatable({}, { __index = commands })
  adapter_commands.git_push_ref_update = function(...)
    wait_at_push_barrier()
    return commands.git_push_ref_update(...)
  end
  local grant_adapter = capacity.production_adapter({ commands = adapter_commands })
  local controller = capacity.new({
    max_inflight = config.max_inflight,
    write_enabled = function()
      return config.write_mode() == "real"
    end,
    owner = claims.claim_owner,
    list_open_claim_numbers = function(_repo, configured_owner)
      local numbers = {}
      for _, number in ipairs(issue_numbers()) do
        local current = issue(number)
        if current.state == "OPEN"
          and claims.issue_claim_state(current.assignees, configured_owner, current.labels) == "self" then
          table.insert(numbers, number)
        end
      end
      return numbers
    end,
    read_issue = function(_repo, number)
      return issue(number)
    end,
    read_grant = grant_adapter.read_grant,
    compare_and_swap_grant = grant_adapter.compare_and_swap_grant,
    release_claim_if_self = function(_repo, number, configured_owner, _reason)
      local current = issue(number)
      if claims.issue_claim_state(current.assignees, configured_owner, current.labels) ~= "self" then
        return false
      end
      write(owner_path(number), "")
      return true
    end,
  })

  local claim_ports = setmetatable({
    claim_issue_for_management = function(_core, _dept, _repo, number)
      local current = issue(number)
      local claim_state = claims.issue_claim_state(current.assignees, claims.claim_owner(), current.labels)
      if claim_state == "self" then
        return true
      end
      if claim_state ~= "unassigned" then
        return false
      end
      write(owner_path(number), claims.claim_owner() .. "\n")
      local fresh = issue(number)
      if claims.issue_claim_state(fresh.assignees, claims.claim_owner(), fresh.labels) ~= "self" then
        error("capacity fixture claim did not become visible")
      end
      if tostring(os.getenv("FKST_CAPACITY_CRASH_AFTER_CLAIM") or "") == tostring(number) then
        local waited = exec_sync({
          cmd = 'while kill -0 "$FKST_SUPERVISOR_PID" 2>/dev/null; do sleep 0.05; done',
          timeout = 30,
        })
        if waited.exit_code ~= 0 then
          error("capacity fixture failed while waiting for supervisor crash")
        end
      end
      return true
    end,
  }, { __index = claims })

  return {
    capacity = controller,
    claims = claim_ports,
    read_current_issue = function(source_ref, updated_at)
      local repo, number = devloop_base.parse_issue_source_ref(source_ref)
      if repo == nil or number == nil then
        return nil, nil, nil, "invalid issue source_ref"
      end
      local current = issue(number)
      current.updated_at = current.updated_at or updated_at
      return repo, number, current, nil
    end,
  }
end

return M
]]
end

local function write_intake_package(root, source)
  local package_root = root .. "/packages/github-devloop-intake"
  run_command("cp -R " .. shell_quote(source .. "/packages/github-devloop-intake") .. " " .. shell_quote(package_root))
  run_command("rm -rf " .. shell_quote(package_root .. "/tests"))
  run_command("mv " .. shell_quote(package_root .. "/departments/admission/main.lua")
    .. " " .. shell_quote(package_root .. "/departments/admission/production.lua"))
  write_file(package_root .. "/core/capacity_harness_deps.lua", capacity_fixture_dependencies())
  write_file(package_root .. "/departments/admission/main.lua", [[
local implementation = require("departments.admission.production")
local deps = require("core.capacity_harness_deps").new()
local M = implementation.make_department(deps)
_G.pipeline = M.pipeline
return M
]])
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/candidate_sink"))
  write_file(package_root .. "/departments/candidate_sink/main.lua", [[
local M = {}

M.spec = {
  consumes = { "devloop_intake_candidate" },
  produces = {},
  stall_window = "5s",
}

function M.pipeline(event)
  local number = assert(event and event.payload and event.payload.issue_number)
  file.write(assert(os.getenv("FKST_CAPACITY_CASE_ROOT")) .. "/delivered/" .. tostring(number), "delivered\n")
end

return M
]])
  return package_root
end

local function write_project(root, source)
  run_command("mkdir -p " .. shell_quote(root .. "/packages"))
  run_command("mkdir -p " .. shell_quote(root .. "/trigger"))
  run_command("cp -R " .. shell_quote(source .. "/libraries") .. " " .. shell_quote(root .. "/libraries"))
  write_file(root .. "/fkst.workspace.toml", [[
[workspace]
units = ["packages/*", "libraries/*"]
packages = ["packages/*"]
libraries = ["libraries/*"]

[registries]
workspace = "workspace"
]])
  local proxy = write_proxy_package(root)
  local intake = write_intake_package(root, source)
  return proxy, intake
end

local function init_git_fixture(root)
  local remote = root .. "/remote.git"
  local clone_a = root .. "/runtime-a-repo"
  local clone_b = root .. "/runtime-b-repo"
  run_command("git init --bare " .. shell_quote(remote))
  run_command("git init -b main " .. shell_quote(root))
  run_command("git -C " .. shell_quote(root) .. " config user.email fkst-test@example.invalid")
  run_command("git -C " .. shell_quote(root) .. " config user.name fkst-test")
  write_file(root .. "/.fixture-root", "fixture\n")
  run_command("git -C " .. shell_quote(root) .. " add .fixture-root")
  run_command("git -C " .. shell_quote(root) .. " commit -m fixture")
  run_command("git -C " .. shell_quote(root) .. " remote add origin " .. shell_quote(remote))
  run_command("git -C " .. shell_quote(root) .. " push origin main")
  run_command("git --git-dir=" .. shell_quote(remote) .. " symbolic-ref HEAD refs/heads/main")
  run_command("git clone " .. shell_quote(remote) .. " " .. shell_quote(clone_a))
  run_command("git clone " .. shell_quote(remote) .. " " .. shell_quote(clone_b))
  for _, clone in ipairs({ clone_a, clone_b }) do
    run_command("git -C " .. shell_quote(clone) .. " config user.email fkst-test@example.invalid")
    run_command("git -C " .. shell_quote(clone) .. " config user.name fkst-test")
  end
  return remote, clone_a, clone_b
end

local function case_root(root, name)
  local selected = root .. "/cases/" .. name
  run_command("mkdir -p " .. shell_quote(selected .. "/issues"))
  run_command("mkdir -p " .. shell_quote(selected .. "/delivered"))
  run_command("mkdir -p " .. shell_quote(selected .. "/barrier"))
  return selected
end

local function write_issue(selected, number, state, decision, dev_state, assignee)
  write_file(selected .. "/issues/" .. tostring(number) .. ".fact", table.concat({
    state or "OPEN",
    decision or "",
    dev_state or "",
    "",
  }, "\n"))
  write_file(selected .. "/issues/" .. tostring(number) .. ".owner", assignee and (assignee .. "\n") or "")
end

local function issue_owner(selected, number)
  return tostring(read_optional(selected .. "/issues/" .. tostring(number) .. ".owner") or ""):gsub("%s+$", "")
end

local function delivered(selected, number)
  return read_optional(selected .. "/delivered/" .. tostring(number)) ~= nil
end

local function active_claim_count(selected, numbers)
  local count = 0
  for _, number in ipairs(numbers) do
    local fact = assert(read_optional(selected .. "/issues/" .. tostring(number) .. ".fact"))
    local state, decision, dev_state = fact:match("^([^\n]*)\n([^\n]*)\n([^\n]*)")
    local active = state == "OPEN" and decision ~= "decline"
      and dev_state ~= "declined" and dev_state ~= "blocked" and dev_state ~= "merged"
    if active and issue_owner(selected, number) == owner then
      count = count + 1
    end
  end
  return count
end

local function remote_grant(remote, repo)
  local ref = capacity.grant_ref(repo, owner)
  local listed = read_command("git ls-remote " .. shell_quote(remote) .. " " .. shell_quote(ref))
  local sha = listed:match("^(%x+)")
  if sha == nil then
    return nil
  end
  local commit = read_command("git --git-dir=" .. shell_quote(remote) .. " cat-file -p " .. shell_quote(sha))
  local body = commit:match("\n\n(.*)")
  return json.decode(assert(body)), sha
end

local function fixture_logs(root)
  local output = command_output("for path in " .. shell_quote(root) .. "/*.stdout "
    .. shell_quote(root) .. "/*.stderr; do"
    .. " [ -f \"$path\" ] || continue;"
    .. " echo FILE:$path; tail -80 \"$path\";"
    .. " done")
  return output
end

local function start_supervise(args)
  local parts = {
    "PATH=" .. shell_quote(system_path),
    "HOME=" .. shell_quote(os.getenv("HOME") or "/tmp"),
    "GIT_AUTHOR_NAME=" .. shell_quote("fkst-test"),
    "GIT_AUTHOR_EMAIL=" .. shell_quote("fkst-test@example.invalid"),
    "GIT_COMMITTER_NAME=" .. shell_quote("fkst-test"),
    "GIT_COMMITTER_EMAIL=" .. shell_quote("fkst-test@example.invalid"),
    "FKST_RUNTIME_ROOT=" .. shell_quote(args.runtime),
    "FKST_DURABLE_ROOT=" .. shell_quote(args.durable),
    "FKST_RATE_POOL_ROOT=" .. shell_quote(args.durable .. "/rate-pools"),
    "FKST_GITHUB_REPO=" .. shell_quote(args.repo),
    "FKST_GITHUB_BOT_LOGIN=" .. shell_quote(owner),
    "FKST_GITHUB_WRITE=1",
    "FKST_GITHUB_CLAIM_MODE=assignee",
    "FKST_DEVLOOP_MAX_INFLIGHT=1",
    "FKST_CAPACITY_CASE_ROOT=" .. shell_quote(args.case),
    "FKST_CAPACITY_ISSUES=" .. shell_quote(args.issues),
    "FKST_CAPACITY_ISSUE_NUMBER=" .. shell_quote(args.issue),
    "FKST_CAPACITY_UPDATED_AT=" .. shell_quote(args.updated_at),
    "FKST_CAPACITY_RUNTIME_ID=" .. shell_quote(args.id),
    "FKST_CAPACITY_BARRIER_PEERS=" .. shell_quote(args.barrier or ""),
    "FKST_CAPACITY_CRASH_AFTER_CLAIM=" .. shell_quote(args.crash_after_claim or ""),
    shell_quote(args.bin),
    "supervise",
    "--project-root", shell_quote(args.project),
    "--package-root", shell_quote(args.proxy),
    "--package-root", shell_quote(args.intake),
    "--framework-bin", shell_quote(args.bin),
  }
  local command = "(cd " .. shell_quote(args.clone) .. " && exec env " .. table.concat(parts, " ") .. ")"
    .. " >" .. shell_quote(args.log .. ".stdout")
    .. " 2>" .. shell_quote(args.log .. ".stderr")
    .. " & printf '%s\\n' \"$!\""
  local output = read_command(command)
  local pid = tonumber(output:match("(%d+)"))
  if pid == nil then
    error("intake capacity production harness did not return a supervise pid: " .. tostring(output))
  end
  return pid
end

local function args(base, overrides)
  local selected = {}
  for key, value in pairs(base) do
    selected[key] = value
  end
  for key, value in pairs(overrides or {}) do
    selected[key] = value
  end
  return selected
end

return {
  -- Regression #438/#2379: intake capacity is one remote CAS authority across runtime generations.
  test_real_cas_department_delivery_and_restart_harness = function()
    local source = repo_root()
    local root = read_command("mktemp -d " .. shell_quote("/tmp/fkst-intake-capacity-production.XXXXXX")):gsub("%s+$", "")
    local active = {}
    local ok, err = pcall(function()
      local bin = framework_bin()
      local proxy, intake = write_project(root, source)
      local remote, clone_a, clone_b = init_git_fixture(root)
      write_file(root .. "/trigger/input.trigger", "ready\n")
      local base = {
        bin = bin,
        project = root,
        proxy = proxy,
        intake = intake,
      }
      local logs = function()
        return fixture_logs(root)
      end

      local concurrent = case_root(root, "concurrent")
      write_issue(concurrent, 41, "OPEN", "", "", nil)
      write_issue(concurrent, 42, "OPEN", "", "", nil)
      local common = {
        case = concurrent,
        repo = "owner/concurrent",
        issues = "41,42",
        updated_at = "2026-07-17T00:00:00Z",
        barrier = "a,b",
      }
      local pid_a = start_supervise(args(base, {
        clone = clone_a, runtime = root .. "/runtime-concurrent-a", durable = root .. "/durable-concurrent-a",
        log = root .. "/concurrent-a", id = "a", issue = "41",
        case = common.case, repo = common.repo, issues = common.issues, updated_at = common.updated_at, barrier = common.barrier,
      }))
      active[pid_a] = true
      local pid_b = start_supervise(args(base, {
        clone = clone_b, runtime = root .. "/runtime-concurrent-b", durable = root .. "/durable-concurrent-b",
        log = root .. "/concurrent-b", id = "b", issue = "42",
        case = common.case, repo = common.repo, issues = common.issues, updated_at = common.updated_at, barrier = common.barrier,
      }))
      active[pid_b] = true
      wait_until("both runtimes to contend on the real remote ref", logs, function()
        return read_optional(concurrent .. "/barrier/a.ready") ~= nil
          and read_optional(concurrent .. "/barrier/b.ready") ~= nil
      end)
      wait_until("exactly one concurrent intake candidate delivery", logs, function()
        local deliveries = (delivered(concurrent, 41) and 1 or 0) + (delivered(concurrent, 42) and 1 or 0)
        if deliveries == 1 and active_claim_count(concurrent, { 41, 42 }) == 1 then
          return true
        end
        return nil, "deliveries=" .. tostring(deliveries)
          .. " active_claims=" .. tostring(active_claim_count(concurrent, { 41, 42 }))
      end)
      local concurrent_grant = assert(remote_grant(remote, common.repo))
      t.eq(#concurrent_grant.holders, 1)
      t.eq(active_claim_count(concurrent, { 41, 42 }), 1)
      stop_process(pid_a)
      stop_process(pid_b)
      active[pid_a] = nil
      active[pid_b] = nil

      local restart = case_root(root, "restart")
      write_issue(restart, 61, "OPEN", "", "", nil)
      write_file(root .. "/trigger/input.trigger", "restart\n")
      local first_pid = start_supervise(args(base, {
        clone = clone_a, runtime = root .. "/runtime-before-restart", durable = root .. "/durable-restart",
        log = root .. "/before-restart", id = "before-restart", issue = "61", case = restart,
        repo = "owner/restart", issues = "61", updated_at = "2026-07-17T00:01:00Z", crash_after_claim = "61",
      }))
      active[first_pid] = true
      wait_until("claim acquisition before candidate delivery", logs, function()
        if issue_owner(restart, 61) == owner and not delivered(restart, 61) then
          return true
        end
        return nil, "owner=" .. issue_owner(restart, 61) .. " delivered=" .. tostring(delivered(restart, 61))
      end)
      stop_process(first_pid, "KILL")
      active[first_pid] = nil
      local second_pid = start_supervise(args(base, {
        clone = clone_b, runtime = root .. "/runtime-after-restart", durable = root .. "/durable-restart",
        log = root .. "/after-restart", id = "after-restart", issue = "61", case = restart,
        repo = "owner/restart", issues = "61", updated_at = "2026-07-17T00:01:00Z",
      }))
      active[second_pid] = true
      wait_until("durable replay delivery from the fresh runtime root", logs, function()
        return delivered(restart, 61)
      end)
      local restart_grant = assert(remote_grant(remote, "owner/restart"))
      t.eq(restart_grant.holders[1], 61)
      t.eq(active_claim_count(restart, { 61 }), 1)
      stop_process(second_pid)
      active[second_pid] = nil

      local converge = case_root(root, "converge")
      write_issue(converge, 1, "OPEN", "enable", "thinking", owner)
      write_issue(converge, 2, "OPEN", "decline", "", owner)
      write_issue(converge, 3, "OPEN", "enable", "thinking", owner)
      write_issue(converge, 4, "OPEN", "", "", nil)
      write_file(root .. "/trigger/input.trigger", "converge\n")
      local converge_pid = start_supervise(args(base, {
        clone = clone_a, runtime = root .. "/runtime-converge", durable = root .. "/durable-converge",
        log = root .. "/converge", id = "converge", issue = "4", case = converge,
        repo = "owner/converge", issues = "1,2,3,4", updated_at = "2026-07-17T00:02:00Z",
      }))
      active[converge_pid] = true
      wait_until("overclaimed repository convergence", logs, function()
        if issue_owner(converge, 1) == owner
          and issue_owner(converge, 2) == ""
          and issue_owner(converge, 3) == ""
          and not delivered(converge, 4) then
          return true
        end
        return nil, "owners=" .. table.concat({
          issue_owner(converge, 1), issue_owner(converge, 2), issue_owner(converge, 3), issue_owner(converge, 4),
        }, ",")
      end)
      local converge_grant = assert(remote_grant(remote, "owner/converge"))
      t.eq(converge_grant.holders[1], 1)
      t.eq(active_claim_count(converge, { 1, 2, 3, 4 }), 1)
      stop_process(converge_pid)
      active[converge_pid] = nil

      write_issue(converge, 1, "CLOSED", "enable", "thinking", owner)
      write_file(root .. "/trigger/input.trigger", "successor\n")
      local successor_pid = start_supervise(args(base, {
        clone = clone_b, runtime = root .. "/runtime-successor", durable = root .. "/durable-successor",
        log = root .. "/successor", id = "successor", issue = "4", case = converge,
        repo = "owner/converge", issues = "1,2,3,4", updated_at = "2026-07-17T00:03:00Z",
      }))
      active[successor_pid] = true
      wait_until("successor admission after winner termination", logs, function()
        if delivered(converge, 4) and issue_owner(converge, 4) == owner then
          return true
        end
        return nil, "successor_owner=" .. issue_owner(converge, 4)
          .. " delivered=" .. tostring(delivered(converge, 4))
      end)
      local successor_grant = assert(remote_grant(remote, "owner/converge"))
      t.eq(successor_grant.holders[1], 4)
      t.eq(issue_owner(converge, 1), "")
      t.eq(active_claim_count(converge, { 1, 2, 3, 4 }), 1)
      stop_process(successor_pid)
      active[successor_pid] = nil
    end)

    for pid in pairs(active) do
      pcall(stop_process, pid, "KILL")
    end
    local failure_logs = not ok and fixture_logs(root) or ""
    local failure = tostring(err)
      .. (failure_logs ~= "" and (" fixture_logs=" .. failure_logs:gsub("%s+", " "):sub(-4000)) or "")
    local cleanup_ok, cleanup_err = pcall(remove_fixture, root)
    if not ok then
      error(failure)
    end
    if not cleanup_ok then
      error(cleanup_err)
    end
  end,
}
