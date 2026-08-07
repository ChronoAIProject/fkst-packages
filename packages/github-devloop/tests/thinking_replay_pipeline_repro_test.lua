local devloop_base = require("devloop.base")
local consensus_core = require("consensus.core")
local context_bundle_identity = require("contract.context_bundle_identity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local liveness_scan = require("devloop.liveness_scan")
local payloads_builders = require("devloop.payloads.builders")
local replay_thinking = require("devloop.replay_thinking_convergence")
local validate_proposal = require("devloop.validators.validate_proposal")

local t = h.t
local core = h.core
local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local source_ref = { kind = "external", ref = "owner/repo#issue/42" }
local fixture_prefix = "/tmp/fkst-thinking-replay-pipeline."
local verdict_label = "⟦FKST:VERDICT⟧"
local reply_label = "⟦FKST:REPLY⟧"
local stance_label = "⟦FKST:STANCE⟧"

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
    error("thinking replay pipeline fixture command failed: " .. tostring(command) .. "\n" .. tostring(output))
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
    error("thinking replay pipeline fixture requires BIN")
  end
  return bin
end

local function remove_fixture(root)
  if root:sub(1, #fixture_prefix) ~= fixture_prefix then
    error("refusing to remove unexpected fixture root: " .. tostring(root))
  end
  run_command("rm -rf " .. shell_quote(root))
end

local function state_comment(version, created_at)
  return {
    body = core.state_marker(proposal_id, "thinking", version),
    author_login = "fkst-test-bot",
    created_at = created_at,
  }
end

local function find_raise(result, queue)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue or raised.queue == "github-devloop." .. queue then
      return raised
    end
  end
  return nil
end

local function mock_thinking_issue(comments, updated_at)
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = issue_number,
    title = "Issue 42 has a nonempty title",
    body = "",
    state = "OPEN",
    updated_at = updated_at,
    labels = { "fkst-dev:enabled", "fkst-dev:thinking" },
    comments = comments,
    assignees = { "fkst-test-bot" },
    times = 1,
  })
end

local function run_liveness_thinking_replay(version)
  local updated_at = "2026-06-03T01:02:03Z"
  t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = '[{"number":42,"state":"open","updated_at":"' .. updated_at .. '"}]\n',
    stderr = "",
    exit_code = 0,
  })
  mock_thinking_issue({ state_comment(version, "2026-06-03T00:00:00Z") }, updated_at)
  h.mock_context_bundle({
    proposal_id = proposal_id,
    dedup_key = version,
    source_ref = source_ref,
  })
  return h.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = { schema = "github-devloop.tick.v1" },
    ts = "2026-06-03T02:00:00Z",
  }, h.opts("thinking-replay-pipeline-liveness"))
end

local function run_observe_level_replay(version, name, event_ts)
  mock_thinking_issue({
    state_comment(version, os.date("!%Y-%m-%dT%H:%M:%SZ", now() - 60)),
  }, "2026-06-03T01:02:03Z")
  local payload = h.issue({
    labels = { "fkst-dev:enabled", "fkst-dev:thinking" },
  })
  h.mock_context_bundle(payload)
  return h.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = payload,
    ts = event_ts,
  }, h.opts(name))
end

local function run_observe_generation(version, name, event_ts, root)
  mock_thinking_issue({
    state_comment(version, os.date("!%Y-%m-%dT%H:%M:%SZ", now() - 60)),
  }, "2026-06-03T01:02:03Z")
  local payload = h.issue({
    labels = { "fkst-dev:enabled", "fkst-dev:thinking" },
    proposal_id = proposal_id,
    dedup_key = version,
  })
  local run_opts = h.opts(name, { FKST_RUNTIME_ROOT = root })
  run_opts.context_runtime_root_mock_times = 1
  run_opts.strict_context_path_probe_mocks = true
  h.mock_context_bundle(payload, run_opts)
  local result = h.run_department("departments/observe_issue/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = payload,
    ts = event_ts,
  }, run_opts)
  return result, run_opts
end

local function clear_context_bundle_cache(content_fetch)
  local manifest_key = assert(tostring(content_fetch):match("^runtime%-cache:(.+)$"))
  t.eq(manifest_key:sub(1, #context_bundle_identity.manifest_cache_prefix),
    context_bundle_identity.manifest_cache_prefix)
  local relative = manifest_key:sub(#context_bundle_identity.manifest_cache_prefix + 1)
  local bundle_key = context_bundle_identity.bundle_cache_prefix .. relative
  -- A runtime-root rotation starts a new engine with a fresh ephemeral cache.
  cache_set(manifest_key, "")
  cache_set(bundle_key, "")
  t.eq(cache_get(manifest_key), "")
  t.eq(cache_get(bundle_key), "")
end

local function mock_consensus_convergence(root)
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = root,
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 11 do
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
  end
  for _ = 1, 5 do
    t.mock_command("codex exec", {
      stdout = verdict_label .. " abstain\n" .. reply_label .. " More evidence is required.\n",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 5 do
    t.mock_command("codex exec", {
      stdout = stance_label .. " defend\n"
        .. verdict_label .. " abstain\n"
        .. reply_label .. " The evidence gap remains.\n",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command("codex exec", {
    stdout = "converge: generation context is readable + inspect the remaining evidence\n"
      .. "open: remaining evidence is unresolved\n",
    stderr = "",
    exit_code = 0,
  })
end

local function remove_generation(root)
  if root:sub(1, #fixture_prefix) ~= fixture_prefix then
    error("refusing to remove unexpected generation root: " .. tostring(root))
  end
  run_command("rm -rf " .. shell_quote(root))
end

local function lua_value(value)
  return string.format("%q", tostring(value or ""))
end

local function write_collapse_fixture(root, proposals)
  local source_root = project_root()
  local package_root = root .. "/packages/github-devloop"
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/initial"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/departments/consensus_result"))
  run_command("mkdir -p " .. shell_quote(package_root .. "/tests"))
  run_command("cp -R " .. shell_quote(source_root .. "/libraries") .. " " .. shell_quote(root .. "/libraries"))
  run_command("find " .. shell_quote(root .. "/libraries") .. " -type d -name tests -prune -exec rm -rf {} +")

  file.write(root .. "/fkst.workspace.toml", [[
[workspace]
units = ["packages/*", "libraries/*"]
packages = ["packages/*"]
libraries = ["libraries/*"]
]])
  file.write(package_root .. "/fkst.toml", [[
kind = "package"
name = "github-devloop"

[code]
root = "."

[lib_deps]
libraries = ["testkit"]
]])

  local proposal_sources = {}
  for index, proposal in ipairs(proposals) do
    local delivery = assert(proposal.redrive_delivery)
    table.insert(proposal_sources, table.concat({
      "local function proposal_" .. tostring(index) .. "()",
      "  return {",
      "    schema = " .. lua_value(proposal.schema) .. ",",
      "    proposal_id = " .. lua_value(proposal.proposal_id) .. ",",
      "    title = " .. lua_value(proposal.title) .. ",",
      "    body = " .. lua_value(proposal.body) .. ",",
      "    worktree = \".\",",
      "    dedup_key = " .. lua_value(proposal.dedup_key) .. ",",
      "    effect_version = " .. lua_value(proposal.effect_version) .. ",",
      "    redrive_delivery = {",
      "      generation_key = " .. lua_value(delivery.generation_key) .. ",",
      "      attempt = " .. tostring(delivery.attempt) .. ",",
      "    },",
      "    source_ref = { kind = \"external\", ref = \"owner/repo#issue/42\" },",
      "  }",
      "end",
    }, "\n"))
  end
  local proposal_source = table.concat(proposal_sources, "\n\n")

  file.write(package_root .. "/departments/initial/main.lua", proposal_source .. [[

local M = {}
M.spec = {
  consumes = { "fixture_start" },
  produces = { "devloop_consensus_request" },
  stall_window = "1s",
}
function M.pipeline(_event)
  raise("devloop_consensus_request", proposal_1())
  raise("devloop_consensus_request", proposal_1())
  raise("devloop_consensus_request", proposal_2())
end
return M
]])
  file.write(package_root .. "/departments/consensus_result/main.lua", [[
local M = {}
M.spec = {
  consumes = { "devloop_consensus_request" },
  produces = {},
  stall_window = "1s",
}
function M.pipeline(event)
  log.info("fixture-consensus-received dedup_key=" .. tostring(event.payload.dedup_key))
end
return M
]])
  file.write(package_root .. "/tests/durable_duplicate_collapse_test.lua", [[
local graph = require("testkit.graph")
local t = fkst.test

return {
  test_two_level_replay_raises_reach_consensus_receiver = function()
    local trace = graph.require_quiescent(graph.run({
      queue = "fixture_start",
      payload = { schema = "thinking-replay-fixture.v1" },
      source_ref = { kind = "external", reference = "owner/repo#issue/42" },
    }, { max_steps = 6 }))

    local consensus_deliveries = 0
    for _, step in ipairs(trace.steps) do
      if step.queue == "github-devloop.devloop_consensus_request"
        and step.consumer == "github-devloop.consensus_result" then
        consensus_deliveries = consensus_deliveries + 1
      end
    end
    t.eq(consensus_deliveries, 2)
  end,
}
]])
  return package_root
end

local function prove_duplicate_level_replay_delivery(proposals)
  local root = read_command("mktemp -d " .. shell_quote(fixture_prefix .. "XXXXXX")):gsub("%s+$", "")
  local ok, err = pcall(function()
    local package_root = write_collapse_fixture(root, proposals)
    read_command(table.concat({
      "FKST_RUNTIME_ROOT=" .. shell_quote(root .. "/runtime"),
      "FKST_DURABLE_ROOT=" .. shell_quote(root .. "/durable"),
      "FKST_RATE_POOL_ROOT=" .. shell_quote(root .. "/durable/rate-pools"),
      shell_quote(framework_bin()),
      "test",
      "--project-root", shell_quote(root),
      "--package-root", shell_quote(package_root),
    }, " "))
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
  test_liveness_scan_thinking_replay_uses_a_consumable_full_issue_proposal = function()
    local version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local sparse = liveness_scan.liveness_scan_issue_entity(repo, issue_number)
    local rebuilt = payloads_builders.build_proposal(sparse)
    rebuilt.dedup_key = version
    rebuilt.content_fetch = "runtime-cache:fixture"
    t.eq(rebuilt.title, "")
    t.eq(validate_proposal.validate_proposal(rebuilt), false)
    rebuilt.title = "Issue 42 has a nonempty title"
    t.eq(validate_proposal.validate_proposal(rebuilt), true)

    local loop_proposal = nil
    local loop_rebuilt = replay_thinking.build_replay_proposal({
      latest_complete_converge_round = function()
        return { round = 0, dedup = version }
      end,
      context_fetch = function()
        return "runtime-cache:fixture-loop"
      end,
      build_board_loop = function(loop_repo, loop_number, current, loop_source_ref,
        round, converge, _tick, content_fetch, dedup_key)
        loop_proposal = payloads_builders.build_loop_proposal(loop_repo, loop_number,
          current, loop_source_ref, round, converge, content_fetch, dedup_key)
        return loop_proposal
      end,
    }, sparse, proposal_id, { version = version }, { comments = {} }, "2026-06-03T02:00:00Z")
    t.eq(loop_rebuilt, nil)
    t.eq(loop_proposal.title, "")
    t.eq(validate_proposal.validate_proposal(loop_proposal), false)
    loop_proposal.title = "Issue 42 has a nonempty title"
    t.eq(validate_proposal.validate_proposal(loop_proposal), true)

    local result = run_liveness_thinking_replay(version)
    t.eq(result.exit_code, 0)
    local attempt = find_raise(result, "github-proxy.github_issue_comment_request")
    t.is_true(attempt ~= nil)
    local consensus = find_raise(result, "devloop_consensus_request")
    if consensus == nil then
      error("thinking replay reproduction: liveness_scan omitted devloop_consensus_request after title validation failed")
    end
  end,

  test_observe_issue_level_replay_gets_a_fresh_durable_delivery = function()
    local version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local first = run_observe_level_replay(version, "thinking-level-replay-first", "2026-06-03T02:00:01Z")
    local second = run_observe_level_replay(version, "thinking-level-replay-second", "2026-06-03T02:00:02Z")
    t.eq(first.exit_code, 0)
    t.eq(second.exit_code, 0)
    local first_request = find_raise(first, "devloop_consensus_request")
    local second_request = find_raise(second, "devloop_consensus_request")
    t.is_true(first_request ~= nil)
    t.is_true(second_request ~= nil)
    t.eq(first_request.payload.effect_version, version)
    t.eq(second_request.payload.effect_version, version)
    t.is_true(first_request.payload.dedup_key ~= version)
    t.is_true(second_request.payload.dedup_key ~= version)
    t.is_true(first_request.payload.dedup_key ~= second_request.payload.dedup_key)
    t.eq(first_request.payload.redrive_delivery.attempt, 1)
    t.eq(second_request.payload.redrive_delivery.attempt, 1)
    t.is_true(first_request.payload.redrive_delivery.generation_key
      ~= second_request.payload.redrive_delivery.generation_key)

    prove_duplicate_level_replay_delivery({ first_request.payload, second_request.payload })
  end,

  test_rotated_generation_real_thinking_replay_reaches_consensus_continuation_without_root_a_reads = function()
    local version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local generation_base = read_command("mktemp -d " .. shell_quote(fixture_prefix .. "generation.XXXXXX")):gsub("%s+$", "")
    local root_a = generation_base .. "/root-a"
    local root_b = generation_base .. "/root-b"
    local first = run_observe_generation(version, "thinking-generation-root-a", "2026-06-03T02:00:11Z", root_a)
    local first_request = find_raise(first, "devloop_consensus_request")
    t.eq(first.exit_code, 0)
    t.is_true(first_request ~= nil)
    clear_context_bundle_cache(first_request.payload.content_fetch)
    local root_b_call_start = #t.command_calls()
    local second, root_b_opts = run_observe_generation(version, "thinking-generation-root-b", "2026-06-03T02:00:12Z", root_b)
    local second_request = find_raise(second, "devloop_consensus_request")

    t.eq(second.exit_code, 0)
    t.is_true(second_request ~= nil)
    t.eq(first_request.payload.content_fetch, second_request.payload.content_fetch)

    local manifest_key = tostring(second_request.payload.content_fetch):match("^runtime%-cache:(.+)$")
    local identity = assert(context_bundle_identity.from_key(
      manifest_key,
      context_bundle_identity.manifest_cache_prefix
    ))
    local root_b_dir = root_b .. "/context/"
      .. identity.proposal_directory_segment .. "/" .. identity.version_directory_segment
    local identity_handle = io.open(root_b_dir .. "/" .. context_bundle_identity.identity_file_name, "r")
    local bound_identity = identity_handle and identity_handle:read("*a") or nil
    if identity_handle ~= nil then
      identity_handle:close()
    end
    t.eq(bound_identity, manifest_key)

    remove_generation(root_a)
    mock_consensus_convergence(root_b)
    local result = h.run_department("departments/consensus_result/main.lua", {
      queue = "devloop_consensus_request",
      payload = second_request.payload,
    }, root_b_opts)

    t.eq(result.exit_code, 0)
    local continuation = find_raise(result, "devloop_consensus_continue")
    t.is_true(continuation ~= nil)
    t.eq(continuation.payload.status, "converge")
    t.eq(continuation.payload.proposal_id, proposal_id)
    local saw_root_b_context = false
    local calls = t.command_calls()
    for index = root_b_call_start + 1, #calls do
      local call = calls[index]
      local rendered = tostring(call.rendered or "")
      local stdin = tostring(call.stdin or "")
      t.is_nil(rendered:find(root_a, 1, true))
      t.is_nil(stdin:find(root_a, 1, true))
      if stdin:find(root_b_dir, 1, true) ~= nil then
        saw_root_b_context = true
      end
    end
    t.eq(saw_root_b_context, true)
    remove_generation(generation_base)
  end,
}
