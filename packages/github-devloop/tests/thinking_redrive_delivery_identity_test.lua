local devloop_base = require("devloop.base")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local payloads_builders = require("devloop.payloads.builders")
local strings = require("contract.strings")

local t = h.t
local core = h.core

local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local runtime_root = "/tmp/fkst-packages-test/github-devloop-thinking-redrive-delivery/runtime"
local fixture_prefix = "/tmp/fkst-thinking-redrive."

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local testing = require("testkit_internal.testing")
local command_output = testing.command_output

local function read_command(command)
  local output, ok = command_output(command)
  if not ok then
    error("thinking redrive fixture command failed: " .. tostring(command) .. "\n" .. tostring(output))
  end
  return output
end

local function run_command(command)
  read_command(command)
end

local function project_root()
  return read_command("pwd"):gsub("%s+$", "")
end

local function framework_bin()
  local bin = os.getenv("BIN") or ""
  if bin == "" then
    error("thinking redrive delivery fixture requires BIN")
  end
  return bin
end

local function remove_fixture(root)
  if root:sub(1, #fixture_prefix) ~= fixture_prefix then
    error("refusing to remove unexpected fixture root: " .. tostring(root))
  end
  run_command("rm -rf " .. shell_quote(root))
end

local function state_comment(version)
  return {
    body = core.state_marker(proposal_id, "thinking", version),
    created_at = "2026-06-03T00:00:00Z",
  }
end

local function run_redrive(event, logical_version, prior_attempt_body, round)
  local comments = { state_comment(logical_version) }
  if prior_attempt_body ~= nil then
    table.insert(comments, {
      body = prior_attempt_body,
      created_at = "2026-06-03T00:10:00Z",
    })
  end
  entity_read_mocks.mock_issue_read_with_defaults(
    t,
    { "fkst-dev:enabled", "fkst-dev:thinking" },
    comments,
    {
      repo = repo,
      number = issue_number,
      state = "OPEN",
      assignees = { "fkst-test-bot" },
      times = 1,
    }
  )
  return h.run_observe(event, h.opts("thinking-redrive-delivery-round-" .. tostring(round), {
    now = "2026-06-03T02:00:00Z",
    env = { FKST_RUNTIME_ROOT = runtime_root },
  }))
end

local function raises_for(result, queue)
  local values = {}
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue or raised.queue == "github-devloop." .. queue then
      table.insert(values, raised)
    end
  end
  return values
end

local function lua_value(value)
  if value == nil then
    return "nil"
  end
  return string.format("%q", value)
end

local function lua_list(values)
  local rendered = {}
  for index, value in ipairs(values) do
    rendered[index] = lua_value(value)
  end
  return "{ " .. table.concat(rendered, ", ") .. " }"
end

local function delivery_source(logical_version, delivery_keys, effect_versions)
  return table.concat({
    "local logical_version = " .. lua_value(logical_version),
    "local delivery_keys = " .. lua_list(delivery_keys),
    "local effect_versions = " .. lua_list(effect_versions),
    [[
local function proposal(index)
  local attempt = index - 1
  local value = {
    schema = "consensus.proposal.v1",
    verdict_mode = "converge",
    proposal_id = "github-devloop/issue/owner/repo/42",
    title = "Judge issue 42",
    body = "Decide whether issue 42 is ready.",
    worktree = ".",
    dedup_key = delivery_keys[index],
    effect_version = effect_versions[index],
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
  }
  if attempt > 0 then
    value.redrive_delivery = {
      generation_key = "restart-liveness-v2/thinking/thinking.active/fixture",
      attempt = attempt,
    }
  end
  return value
end
]],
  }, "\n")
end

local function write_delivery_fixture(root, logical_version, requests)
  local source_root = project_root()
  local package_root = root .. "/packages/github-devloop"
  run_command("mkdir -p " .. shell_quote(root .. "/packages"))
  run_command("cp -R " .. shell_quote(source_root .. "/libraries") .. " " .. shell_quote(root .. "/libraries"))
  run_command("find " .. shell_quote(root .. "/libraries") .. " -type d -name tests -prune -exec rm -rf {} +")
  for _, package_name in ipairs({ "github-devloop", "github-proxy", "github-devloop-decompose" }) do
    run_command("cp -R " .. shell_quote(source_root .. "/packages/" .. package_name)
      .. " " .. shell_quote(root .. "/packages/" .. package_name))
    run_command("rm -rf " .. shell_quote(root .. "/packages/" .. package_name .. "/tests"))
  end
  run_command("find " .. shell_quote(root .. "/packages")
    .. " -type d -path '*/departments/test_*' -prune -exec rm -rf {} +")

  run_command("rm -rf " .. shell_quote(package_root .. "/departments"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/consensus_result"))
  run_command("cp " .. shell_quote(source_root .. "/packages/github-devloop/departments/consensus_result/main.lua")
    .. " " .. shell_quote(package_root .. "/departments/consensus_result/main.lua"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/redrive_delivery_fixture_seed"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/redrive_delivery_fixture_chain"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/tests"))

  file.write(root .. "/fkst.workspace.toml", [[
[workspace]
units = ["packages/*", "libraries/*"]
packages = ["packages/*"]
libraries = ["libraries/*"]
]])

  local delivery_keys = { logical_version }
  local effect_versions = { logical_version }
  for _, request in ipairs(requests) do
    table.insert(delivery_keys, request.payload.dedup_key)
    table.insert(effect_versions, request.payload.effect_version)
  end
  local common = delivery_source(logical_version, delivery_keys, effect_versions)
  file.write(package_root .. "/departments/redrive_delivery_fixture_seed/main.lua", common .. [[
local M = {}
M.spec = {
  consumes = { "redrive_delivery_fixture_start" },
  produces = { "devloop_consensus_request" },
  fanout = { "devloop_consensus_request" },
  stall_window = "1s",
}
function M.pipeline(_event)
  raise("devloop_consensus_request", proposal(1))
end
return M
]])
  file.write(package_root .. "/departments/redrive_delivery_fixture_chain/main.lua", common .. [[
local M = {}
M.spec = {
  consumes = { "devloop_consensus_request" },
  produces = { "devloop_consensus_request" },
  fanout = { "devloop_consensus_request" },
  stall_window = "1s",
}
function M.pipeline(event)
  local delivery = event.payload and event.payload.redrive_delivery
  local attempt = type(delivery) == "table" and tonumber(delivery.attempt) or 0
  if attempt < 3 then
    raise("devloop_consensus_request", proposal(attempt + 2))
  end
end
return M
]])
  file.write(package_root .. "/tests/redrive_delivery_graph_test.lua", [[
local consensus_core = require("consensus.core")
local graph = require("testkit.graph")
local testing = require("testkit_internal.testing")

local t = fkst.test
local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"

local function mock_consensus_approval()
  for _ = 1, #consensus_core.angles({}) do
    t.mock_command(consensus_core.checkout_root_exists_cmd("."), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("codex exec", {
      stdout = testing.codex_agent_message_jsonl(
        verdict_label .. " approve\n" .. reply_label .. " delivery reached the receiver.\n"),
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_receiver_boundary()
  for _ = 1, 32 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-thinking-redrive-graph/runtime",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 4 do
    for _, command in ipairs({
      "gh api repos/owner/repo/issues/42",
      "gh api 'repos/owner/repo/issues/42'",
    }) do
      t.mock_command(command, {
        stdout = '{"number":42,"title":"Judge issue 42","body":"","state":"open","created_at":"2026-06-03T01:00:00Z","updated_at":"2026-06-03T01:02:03Z","labels":[],"user":{"login":"outside-author"},"assignees":[{"login":"fkst-test-bot"}]}\n',
        stderr = "",
        exit_code = 0,
      })
    end
    for _, command in ipairs({
      "gh api --paginate --slurp repos/owner/repo/issues/42/comments?per_page=100",
      "gh api --paginate --slurp 'repos/owner/repo/issues/42/comments?per_page=100'",
    }) do
      t.mock_command(command, {
        stdout = "[]\n",
        stderr = "",
        exit_code = 0,
      })
    end
  end
end

return {
  test_canonical_delivery_does_not_suppress_three_fresh_redrives = function()
    mock_consensus_approval()
    mock_receiver_boundary()
    local trace = graph.require_quiescent(graph.run({
      queue = "redrive_delivery_fixture_start",
      payload = { schema = "thinking-redrive-fixture.v1" },
      source_ref = { kind = "external", reference = "owner/repo#issue/42" },
    }, { max_steps = 9 }))

    local first = graph.require_delivery(trace, {
      queue = "github-devloop.devloop_consensus_request",
      consumer = "github-devloop.consensus_result",
    })
    t.eq(first.exit_code, 0)

    local delivery_ids = {}
    local distinct_delivery_ids = 0
    local receiver_deliveries = 0
    for _, step in ipairs(trace.steps) do
      if step.queue == "github-devloop.devloop_consensus_request"
        and step.consumer == "github-devloop.consensus_result" then
        receiver_deliveries = receiver_deliveries + 1
        t.eq(step.exit_code, 0)
        if delivery_ids[step.delivery_id] == nil then
          delivery_ids[step.delivery_id] = true
          distinct_delivery_ids = distinct_delivery_ids + 1
        end
      end
    end
    t.eq(receiver_deliveries, 4)
    t.eq(distinct_delivery_ids, 4)
  end,
}
]])
  return package_root
end

local function prove_durable_deliveries(requests)
  local logical_version = requests[1].payload.effect_version or requests[1].payload.dedup_key
  local root = read_command("mktemp -d " .. shell_quote(fixture_prefix .. "XXXXXX")):gsub("%s+$", "")
  local ok, err = pcall(function()
    local package_root = write_delivery_fixture(root, logical_version, requests)
    local command = table.concat({
      "FKST_RUNTIME_ROOT=" .. shell_quote(root .. "/runtime"),
      "FKST_DURABLE_ROOT=" .. shell_quote(root .. "/durable"),
      shell_quote(framework_bin()),
      "test",
      "--project-root", shell_quote(root),
      "--package-root", shell_quote(package_root),
      "--package-root", shell_quote(root .. "/packages/github-proxy"),
      "--package-root", shell_quote(root .. "/packages/github-devloop-decompose"),
    }, " ")
    read_command(command)
  end)
  local cleanup_ok, cleanup_err = pcall(remove_fixture, root)
  if not ok then
    error(err)
  end
  if not cleanup_ok then
    error(cleanup_err)
  end
end

return {
  test_three_thinking_redrives_get_fresh_deliveries_on_one_logical_lineage = function()
    local event = h.issue()
    local logical_version = payloads_builders.build_proposal(event).dedup_key
    local prior_attempt_body = nil
    local requests = {}

    for round = 1, 3 do
      local result = run_redrive(event, logical_version, prior_attempt_body, round)
      t.eq(result.exit_code, 0)
      local consensus_requests = raises_for(result, "devloop_consensus_request")
      local attempt_requests = raises_for(result, "github-proxy.github_issue_comment_request")
      t.eq(#consensus_requests, 1)
      t.eq(#attempt_requests, 1)
      t.is_true(attempt_requests[1].payload.body:find('round="' .. tostring(round) .. '"', 1, true) ~= nil)
      prior_attempt_body = attempt_requests[1].payload.body
      requests[round] = consensus_requests[1]
    end

    -- The graph fixture consumes and ACKs the canonical request before the first
    -- redrive is inserted, then requires all three redrives at the production receiver.
    prove_durable_deliveries(requests)

    local seen = { [logical_version] = true }
    local generation_key = nil
    for round, request in ipairs(requests) do
      local payload = request.payload
      t.eq(payload.effect_version, logical_version)
      t.eq(payload.redrive_delivery.attempt, round)
      generation_key = generation_key or payload.redrive_delivery.generation_key
      t.eq(payload.redrive_delivery.generation_key, generation_key)
      t.eq(seen[payload.dedup_key], nil)
      t.is_true(strings.is_path_safe_key(payload.dedup_key, devloop_base._max_key_len))
      seen[payload.dedup_key] = true
    end
  end,
}
