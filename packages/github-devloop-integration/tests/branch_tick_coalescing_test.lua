local branch_tick = require("branch_tick")
local branch_poll = require("raisers.branch_poll")
local t = fkst.test

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function read_command(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok = handle:close()
  if ok == false or ok == nil then
    error("branch tick coalescing fixture command failed: " .. tostring(command) .. "\n" .. tostring(output))
  end
  return output
end

local function run_command(command)
  read_command(command)
end

local function repo_root()
  return (read_command("pwd"):gsub("%s+$", ""))
end

local function write_file(path, body)
  file.write(path, body)
end

local function copy_dir(source, target)
  run_command("mkdir -p " .. shell_quote(target))
  run_command("cp -R " .. shell_quote(source) .. "/. " .. shell_quote(target .. "/"))
end

local function setup_workspace()
  local root = (read_command("mktemp -d " .. shell_quote("/tmp/fkst-branch-tick-coalescing.XXXXXX")):gsub("%s+$", ""))
  local source = repo_root()
  local package_root = root .. "/packages/tick-fixture"

  write_file(root .. "/fkst.workspace.toml", '[workspace]\nunits = ["packages/*", "libraries/*"]\n')
  copy_dir(source .. "/libraries", root .. "/libraries")
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/branch_tick"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/source"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/later"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/sink_a"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/sink_b"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/sink_c"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/tests"))
  run_command("cp " .. shell_quote(source .. "/packages/github-devloop-integration/branch_tick.lua")
    .. " " .. shell_quote(package_root .. "/branch_tick.lua"))
  run_command("cp " .. shell_quote(source .. "/packages/github-devloop-integration/departments/branch_tick/main.lua")
    .. " " .. shell_quote(package_root .. "/departments/branch_tick/main.lua"))

  write_file(package_root .. "/fkst.toml", [[
kind = "package"
name = "tick-fixture"

[code]
root = "."

[lib_deps]
libraries = ["workflow"]
]])
  write_file(package_root .. "/departments/source/main.lua", [[
local M = {}
M.spec = {
  consumes = { "seed" },
  produces = { "devloop_branch_poll", "zz_after" },
  stall_window = "30s",
}
function M.pipeline(_event)
  for index = 1, 24 do
    raise("devloop_branch_poll", {
      schema = "fixture.raw-tick.v1",
      dedup_key = "raw/" .. tostring(index),
    })
  end
  raise("zz_after", {
    schema = "fixture.after.v1",
    dedup_key = "after/first-batch",
  })
end
return M
]])
  write_file(package_root .. "/departments/later/main.lua", [[
local M = {}
M.spec = {
  consumes = { "zz_after" },
  produces = { "devloop_branch_poll" },
  stall_window = "30s",
}
function M.pipeline(_event)
  raise("devloop_branch_poll", {
    schema = "fixture.raw-tick.v1",
    dedup_key = "raw/after-ack",
  })
end
return M
]])
  write_file(package_root .. "/departments/sink_a/main.lua", [[
local branch_tick = require("branch_tick")
local M = {}
M.spec = {
  consumes = { "devloop_branch_tick" },
  produces = { "devloop_branch_tick" },
  fanout = { "devloop_branch_tick" },
  stall_window = "30s",
}
function M.pipeline(_event)
  -- Republish while this subscriber's same-key delivery is in flight.
  raise("devloop_branch_tick", branch_tick.payload())
end
return M
]])

  local passive_sink = [[
local M = {}
M.spec = {
  consumes = { "devloop_branch_tick" },
  produces = {},
  fanout = { "devloop_branch_tick" },
  stall_window = "30s",
}
function M.pipeline(_event)
end
return M
]]
  write_file(package_root .. "/departments/sink_b/main.lua", passive_sink)
  write_file(package_root .. "/departments/sink_c/main.lua", passive_sink)

  write_file(package_root .. "/tests/coalescing_child_test.lua", [[
local branch_tick = require("branch_tick")
local t = fkst.test

local function count_consumer(trace, consumer)
  local count = 0
  local delivery_id = nil
  for _, step in ipairs(trace.steps or {}) do
    if step.consumer == consumer then
      count = count + 1
      delivery_id = delivery_id or step.delivery_id
      t.eq(step.delivery_id, delivery_id)
      t.is_true(step.delivery_id:find("/dedup/", 1, true) ~= nil)
    end
  end
  return count, delivery_id
end

return {
  test_constant_key_is_forbid_scoped_per_subscriber_and_rearms_after_ack = function()
    local trace = t.run_graph({
      queue = "seed",
      payload = { schema = "fixture.seed.v1" },
      source_ref = { kind = "external", reference = "fixture#seed/1" },
    }, { max_steps = 64 })

    t.eq(trace.status, "quiescent")

    local bridge_steps = 0
    for _, step in ipairs(trace.steps or {}) do
      if step.queue == "devloop_branch_poll" then
        bridge_steps = bridge_steps + 1
        t.eq(step.consumer, "branch_tick")
        t.eq(#step.raises, 1)
        t.eq(step.raises[1].queue, "devloop_branch_tick")
        t.eq(step.raises[1].payload.dedup_key, branch_tick.dedup_key)
      end
    end
    t.eq(bridge_steps, 25)

    -- Twenty-four queued activations collapse to one delivery per subscriber.
    -- sink_a's same-key in-flight republish is forbidden, while zz_after proves
    -- that the same identity is admitted again after the first delivery acks.
    local count_a, delivery_a = count_consumer(trace, "sink_a")
    local count_b, delivery_b = count_consumer(trace, "sink_b")
    local count_c, delivery_c = count_consumer(trace, "sink_c")
    t.eq(count_a, 2)
    t.eq(count_b, 2)
    t.eq(count_c, 2)
    t.is_true(delivery_a ~= delivery_b)
    t.is_true(delivery_a ~= delivery_c)
    t.is_true(delivery_b ~= delivery_c)
  end,
}
]])
  return root, package_root
end

local function framework_bin()
  local bin = os.getenv("BIN") or ""
  if bin == "" then
    error("branch tick coalescing fixture requires BIN")
  end
  return bin
end

return {
  test_branch_tick_producer_declares_constant_forbid_contract = function()
    t.eq(branch_poll.type, "cron")
    t.eq(branch_poll.interval, branch_tick.poll_interval)
    t.eq(branch_poll.produces, branch_tick.source_queue)
    t.eq(branch_tick.poll_interval, "5m")
    t.eq(branch_tick.overlap_policy, "Forbid")
    t.eq(branch_tick.dedup_key, "github-devloop-integration/devloop-branch-tick/forbid")

    local result = t.run_department("departments/branch_tick/main.lua", {
      queue = branch_tick.source_queue,
      payload = { raiser = "github-devloop-integration.branch_poll" },
    })
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, branch_tick.target_queue)
    t.eq(result.raises[1].payload.schema, branch_tick.schema)
    t.eq(result.raises[1].payload.dedup_key, branch_tick.dedup_key)
  end,

  test_branch_tick_forbid_contract_uses_real_delivery_router = function()
    local root, package_root = setup_workspace()
    local command = table.concat({
      "BIN=" .. shell_quote(framework_bin()),
      "FKST_RUNTIME_ROOT=" .. shell_quote(root .. "/runtime"),
      "FKST_DURABLE_ROOT=" .. shell_quote(root .. "/durable"),
      shell_quote(framework_bin()),
      "test",
      "--project-root",
      shell_quote(package_root),
      "--package-root",
      shell_quote(package_root),
    }, " ")
    local ok, output = pcall(read_command, command)
    pcall(run_command, "rm -rf " .. shell_quote(root))
    if not ok then
      error("fixture_root=" .. tostring(root) .. " " .. tostring(output))
    end
    t.is_true(output:find("1 passed, 0 failed", 1, true) ~= nil, output)
  end,
}
