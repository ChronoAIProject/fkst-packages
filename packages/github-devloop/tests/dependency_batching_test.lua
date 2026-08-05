local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t
local base_ids = require("devloop.base_ids")
local dependency_graphql = require("devloop.dependency_graphql")
local gh_argv = require("testkit_internal.gh_argv_mock")
local author_policy = require("testkit_internal.github_author_policy")

local repo = "owner/repo"

local function mock_author_policy(times)
  author_policy.mock_env(t, nil, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
    times = times or 3,
  })
end

local function encode_json_string(value)
  return tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
end

local function blocked_by_connection(nodes, opts)
  local rendered = {}
  for _, node in ipairs(nodes or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"%s","stateReason":"%s","repository":{"nameWithOwner":"%s"}}',
      tonumber(node.number),
      encode_json_string(node.state or "OPEN"),
      encode_json_string(node.state_reason or ""),
      encode_json_string(node.repo or repo)
    ))
  end
  local options = opts or {}
  return '{"blockedBy":{"totalCount":' .. tostring(options.total_count or #rendered)
    .. ',"pageInfo":{"hasNextPage":' .. tostring(options.has_next_page == true)
    .. '},"nodes":[' .. table.concat(rendered, ",") .. ']}}'
end

local function singleton_stdout(nodes)
  return '{"data":{"repository":{"issue":' .. blocked_by_connection(nodes) .. '}}}\n'
end

local function batch_stdout(entries)
  local rendered = {}
  for _, entry in ipairs(entries or {}) do
    local issue = entry.issue_json
    if issue == nil then
      issue = blocked_by_connection(entry.nodes, entry.options)
    end
    table.insert(rendered, '"issue_' .. tostring(entry.number) .. '":' .. issue)
  end
  return '{"data":{"repository":{' .. table.concat(rendered, ",") .. '}}}\n'
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function batch_command(numbers)
  local query = dependency_graphql.render_batch_query("dependency_blocked_by", {
    owner = "owner",
    name = "repo",
  }, numbers)
  return "gh api graphql -f " .. shell_quote("query=" .. query)
end

local function mock_root(issue_number, nodes)
  mock_author_policy()
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = singleton_stdout(nodes),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_batch(numbers, entries, result)
  t.mock_command(batch_command(numbers), result or {
    stdout = batch_stdout(entries),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocker_issue(issue_number, state)
  local proposal_id = base_ids.proposal_id(repo, issue_number)
  local marker = h.projected_state_comment(
    proposal_id, state or "ready", "v-" .. tostring(issue_number))
  t.mock_command(core.gh_issue_view_observe_cmd(repo, issue_number), {
    stdout = '{"state":"OPEN","comments":[{"body":"' .. encode_json_string(marker)
      .. '","author":{"login":"fkst-test-bot"},"createdAt":"2026-06-03T01:00:00Z"}]'
      .. ',"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function capture_logs(fn)
  local previous_info = log.info
  local previous_error = log.error
  local logs = {}
  log.info = function(message)
    table.insert(logs, tostring(message))
  end
  log.error = function(message)
    table.insert(logs, tostring(message))
  end
  local ok, result = pcall(fn)
  log.info = previous_info
  log.error = previous_error
  if not ok then
    error(result, 0)
  end
  return result, logs
end

local function has_log(logs, fields)
  for _, line in ipairs(logs or {}) do
    local matches = true
    for _, field in ipairs(fields or {}) do
      if line:find(field, 1, true) == nil then
        matches = false
        break
      end
    end
    if matches then
      return true
    end
  end
  return false
end

local function count_exact_calls(command)
  local expected = h.argv_rendered(command)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if h.argv_rendered(gh_argv.call_rendered(call)) == expected then
      count = count + 1
    end
  end
  return count
end

return {
  test_dependency_batch_adapter_uses_one_rate_pool_free_graphql_call = function()
    mock_author_policy(1)
    local calls = {}
    local result = dependency_graphql.execute_batch("dependency_blocked_by", {
      owner = "owner",
      name = "repo",
    }, { 11, 12 }, 35, function(spec)
      table.insert(calls, spec)
      return {
        stdout = batch_stdout({ { number = 11 }, { number = 12 } }),
        stderr = "",
        exit_code = 0,
      }
    end)

    t.eq(result.exit_code, 0)
    t.eq(#calls, 1)
    t.eq(calls[1].timeout, 35)
    t.eq(calls[1].argv[1], "gh")
    t.eq(calls[1].argv[2], "api")
    t.eq(calls[1].argv[3], "graphql")
    t.eq(calls[1].argv[4], "-f")
    t.eq(calls[1].argv[5], "query=" .. dependency_graphql.render_batch_query(
      "dependency_blocked_by",
      { owner = "owner", name = "repo" },
      { 11, 12 }
    ))
    t.is_nil(calls[1].cmd)
    t.is_nil(calls[1].rate_pool)
  end,

  test_dependency_gate_batches_open_siblings_with_behavioral_parity = function()
    mock_root(42, { { number = 11 }, { number = 12 } })
    mock_batch({ 11, 12 }, { { number = 11 }, { number = 12 } })
    mock_blocker_issue(11, "ready")
    mock_blocker_issue(12, "ready")

    local gate, logs = capture_logs(function()
      return core.dependency_gate(repo, 42)
    end)

    t.is_nil(gate.ok)
    t.eq(gate.kind, "waiting")
    t.eq(gate.reason, "waiting-on-dependency")
    t.eq(#gate.unmet, 2)
    t.eq(gate.unmet[1], 11)
    t.eq(gate.unmet[2], 12)
    t.eq(count_exact_calls(core.gh_blocked_by_cmd(repo, 42)), 1)
    t.eq(count_exact_calls(batch_command({ 11, 12 })), 1)
    t.eq(count_exact_calls(core.gh_blocked_by_cmd(repo, 11)), 0)
    t.eq(count_exact_calls(core.gh_blocked_by_cmd(repo, 12)), 0)
    t.is_true(has_log(logs, {
      "operation=dependency_blocked_by",
      "repo=owner/repo",
      "batch_size=2",
      "outcome=success",
    }))
  end,

  test_dependency_batch_truncation_fails_closed = function()
    mock_root(52, { { number = 5201 }, { number = 5202 } })
    mock_batch({ 5201, 5202 }, {
      { number = 5201, nodes = { { number = 7 } }, options = { total_count = 51, has_next_page = true } },
      { number = 5202 },
    })

    local gate, logs = capture_logs(function()
      return core.dependency_gate(repo, 52)
    end)

    t.is_nil(gate.ok)
    t.eq(gate.kind, "unavailable")
    t.eq(gate.reason, "blockedby-truncated")
    t.eq(#gate.unmet, 0)
    t.is_true(has_log(logs, {
      "operation=dependency_blocked_by",
      "batch_size=2",
      "outcome=failure",
      "reason=blockedby-truncated",
    }))
  end,

  test_dependency_batch_malformed_alias_fails_closed = function()
    mock_root(62, { { number = 31 }, { number = 32 } })
    mock_batch({ 31, 32 }, {
      { number = 31, issue_json = "{}" },
      { number = 32 },
    })

    local gate = core.dependency_gate(repo, 62)

    t.is_nil(gate.ok)
    t.eq(gate.kind, "unavailable")
    t.eq(gate.reason, "malformed-json")
    t.eq(#gate.unmet, 0)
  end,

  test_dependency_batch_transport_failure_is_attributed_and_fails_closed = function()
    mock_root(72, { { number = 41 }, { number = 42 } })
    mock_batch({ 41, 42 }, nil, {
      stdout = "",
      stderr = "graphql unavailable",
      exit_code = 1,
    })

    local gate, logs = capture_logs(function()
      return core.dependency_gate(repo, 72)
    end)

    t.is_nil(gate.ok)
    t.eq(gate.kind, "unavailable")
    t.eq(gate.reason, "gh-failed")
    t.eq(#gate.unmet, 0)
    t.is_true(has_log(logs, {
      "operation=dependency_blocked_by",
      "repo=owner/repo",
      "batch_size=2",
      "outcome=failure",
      "reason=gh-failed",
    }))
  end,
}
