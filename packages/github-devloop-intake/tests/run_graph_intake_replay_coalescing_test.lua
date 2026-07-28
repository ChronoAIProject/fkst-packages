local t = fkst.test

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function read_command(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok = handle:close()
  if ok == false or ok == nil then
    error("intake replay coalescing fixture command failed: " .. tostring(command) .. "\n" .. tostring(output))
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
  local root = (read_command("mktemp -d " .. shell_quote("/tmp/fkst-intake-replay-coalescing.XXXXXX")):gsub("%s+$", ""))
  local source = repo_root()
  write_file(root .. "/fkst.workspace.toml", '[workspace]\nunits = ["packages/*", "libraries/*"]\n')
  copy_dir(source .. "/libraries", root .. "/libraries")

  run_command("mkdir -p " .. shell_quote(root .. "/packages/intake-replay-sink/departments/record"))
  write_file(root .. "/packages/intake-replay-sink/fkst.toml", [[
kind = "package"
name = "intake-replay-sink"

[code]
root = "."
]])
  write_file(root .. "/packages/intake-replay-sink/departments/record/main.lua", [[
local M = {}
M.spec = {
  consumes = { "a_fresh", "observed" },
  produces = {},
  published_seam = { "a_fresh", "observed" },
  stall_window = "30s",
}
function M.pipeline(_event)
end
return M
]])

  run_command("mkdir -p " .. shell_quote(root .. "/packages/github-devloop-intake/departments/produce"))
  run_command("mkdir -p " .. shell_quote(root .. "/packages/github-devloop-intake/tests"))
  write_file(root .. "/packages/github-devloop-intake/fkst.toml", [[
kind = "package.composed"
name = "github-devloop-intake"

[code]
root = "."

[lib_deps]
libraries = ["contract", "devloop"]

[event_deps]
packages = ["intake-replay-sink"]
]])
  write_file(root .. "/packages/github-devloop-intake/departments/produce/main.lua", [[
local activation = require("devloop.intake_replay_activation")
local M = {}

M.spec = {
  consumes = { "seed" },
  produces = { "intake-replay-sink.a_fresh", "intake-replay-sink.observed" },
  stall_window = "30s",
}

local function source_ref(number)
  return { kind = "external", ref = "owner/repo#issue/" .. tostring(number) }
end

local function snapshot(source, delivery_id)
  local dead_letters = {}
  if delivery_id ~= nil then
    dead_letters[1] = {
      delivery_id = delivery_id,
      queue = activation.target_queue,
      dept = activation.target_dept,
      source = { kind = source.kind, reference = source.ref },
      attempts = 1,
      permanent = true,
      replayable = false,
      dead_at_ms = 100,
    }
  end
  return {
    truncated = { deliveries = false, dead_letters = false },
    deliveries = {},
    dead_letters = dead_letters,
  }
end

local function raise_repeated(number, delivery_id, count)
  local source = source_ref(number)
  local key = assert(activation.observation_key(snapshot(source, delivery_id), source))
  for _ = 1, count do
    raise("intake-replay-sink.observed", {
      schema = "github-proxy.issue-observed.v1",
      dedup_key = key,
      source_ref = source,
    })
  end
end

function M.pipeline(_event)
  raise("intake-replay-sink.a_fresh", {
    schema = "github-proxy.v1",
    dedup_key = "fresh/99",
    source_ref = source_ref(99),
  })
  for number = 1, 3 do
    raise_repeated(number, nil, 20)
  end
  raise_repeated(4, "delivery/lineage-a", 20)
  raise_repeated(4, "delivery/lineage-b", 20)
end

return M
]])
  write_file(root .. "/packages/github-devloop-intake/tests/coalescing_child_test.lua", [[
local t = fkst.test

local function sink_steps(trace)
  local selected = {}
  for _, step in ipairs(trace.steps or {}) do
    if step.consumer == "intake-replay-sink.record" then
      table.insert(selected, step)
    end
  end
  return selected
end

return {
  test_repeated_states_collapse_and_fresh_work_is_served_first = function()
    local trace = t.run_graph({
      queue = "github-devloop-intake.seed",
      payload = { schema = "fixture.seed.v1" },
      source_ref = { kind = "external", reference = "fixture#seed/1" },
    }, { max_steps = 16 })
    t.eq(trace.status, "quiescent")
    t.eq(#trace.steps[1].raises, 101)

    local delivered = sink_steps(trace)
    t.eq(#delivered, 6)
    t.eq(delivered[1].queue, "intake-replay-sink.a_fresh")

    local observed = 0
    for _, step in ipairs(delivered) do
      if step.queue == "intake-replay-sink.observed" then
        observed = observed + 1
        t.is_true(step.delivery_id:find("/dedup/intake-replay-observation", 1, true) ~= nil)
      end
    end
    t.eq(observed, 5)
  end,
}
]])
  return root
end

local function framework_bin()
  local bin = os.getenv("BIN") or ""
  if bin == "" then
    error("intake replay coalescing fixture requires BIN")
  end
  return bin
end

return {
  test_replay_state_coalescing_uses_production_delivery_identity = function()
    local root = setup_workspace()
    local command = table.concat({
      "BIN=" .. shell_quote(framework_bin()),
      "FKST_RUNTIME_ROOT=" .. shell_quote(root .. "/runtime"),
      "FKST_DURABLE_ROOT=" .. shell_quote(root .. "/durable"),
      shell_quote(framework_bin()),
      "test",
      "--project-root",
      shell_quote(root .. "/packages/github-devloop-intake"),
      "--package-root",
      shell_quote(root .. "/packages/github-devloop-intake"),
      "--package-root",
      shell_quote(root .. "/packages/intake-replay-sink"),
    }, " ")
    local ok, output = pcall(read_command, command)
    pcall(run_command, "rm -rf " .. shell_quote(root))
    if not ok then
      error("fixture_root=" .. tostring(root) .. " " .. tostring(output))
    end
    t.is_true(output:find("1 passed, 0 failed", 1, true) ~= nil, output)
  end,
}
