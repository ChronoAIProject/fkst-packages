local base_ids, h, entity_lib, devloop_base, devloop_logging = require("devloop.base_ids"), require("tests.devloop_helpers"), require("devloop.entity"), require("devloop.base"), require("devloop.logging")
local cache_seed_helpers = require("tests.cache_seed_helpers")
local contract_time = require("contract.time")
local conv_reconcile, conv_attempts = require("devloop.convergence.reconcile"), require("devloop.convergence.attempts")
local m_rae = require("devloop.restart_actionable_epoch")
local t = h.t
local core = h.core
local opts = h.opts
local decompose_lib = require("devloop.decompose")
local issue = h.issue
local mock_issue_state = h.mock_issue_state
local run_observe = h.run_observe
local find_raise = h.find_raise
local render_comment = h.render_comment
local json_string = h.json_string
local ready = h.ready
local replay_fields = require("devloop.replay_fields")
local mock_issue_reconcile = h.mock_issue_reconcile
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local codex_status = require("tests.codex_status_helpers")
local m_builders = require("devloop.markers.builders")
local ISSUE_REDRIVE_QUEUE = "devloop_observe_issue"
local _cache_seed_helpers = cache_seed_helpers

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function run_timeout_reconcile(payload, run_opts)
  return h.run_department("departments/reconcile/main.lua", {
    queue = "devloop_timeout_reconcile",
    payload = payload,
  }, run_opts)
end

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

-- A marker createdAt this many seconds before the (real) wall clock. Liveness budgets
-- compare marker age against now(); hardcoded absolute dates make "not over budget"
-- cases flip to over-budget as wall time advances past the budget window (non-hermetic).
-- Use a recent createdAt so a not-over-budget setup stays not-over-budget deterministically.
local function recent_iso(seconds_ago)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (seconds_ago or 60))
end

local function run_liveness_scan(name, run_opts)
  return h.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
    },
    ts = "2026-06-03T01:32:03Z",
  }, run_opts or opts(name or "liveness-scan"))
end

local function run_liveness_scan_at(name, ts, run_opts)
  return h.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
    },
    ts = ts,
  }, run_opts or opts(name or "liveness-scan"))
end

local mock_repo = require("testkit_internal.env_mocks").bind_mock_repo(devloop_base, repo)

local function numbered_list_json(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"%s","updated_at":"%s"}',
      tonumber(item.number),
      json_string(item.state or "open"),
      json_string(item.updated_at or "")
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]\n"
end

local function blocked_by_json(nodes)
  local rendered = {}
  for _, node in ipairs(nodes or {}) do
    table.insert(rendered, string.format(
      '{"number":%s,"state":"%s","stateReason":"%s","repository":{"nameWithOwner":"%s"}}',
      tostring(node.number),
      json_string(node.state or "OPEN"),
      json_string(node.state_reason or node.stateReason or ""),
      json_string(node.repo or repo)
    ))
  end
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
    .. tostring(#(nodes or {}))
    .. ',"pageInfo":{"hasNextPage":false},"nodes":['
    .. table.concat(rendered, ",")
    .. ']}}}}}\n'
end

local function mock_blocked_by(issue_number, nodes)
  t.mock_command(core.gh_blocked_by_cmd(repo, issue_number), {
    stdout = blocked_by_json(nodes),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_list(items)
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = numbered_list_json(items),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_state_number(issue_number, labels, state, comments, updated_at)
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = issue_number,
    title = "Issue " .. tostring(issue_number),
    body = "",
    state = state or "OPEN",
    updated_at = updated_at or "2026-06-03T01:02:03Z",
    labels = labels,
    comments = comments,
    assignees = { "fkst-test-bot" },
    times = 1,
  })
end

local function mock_empty_pr_list()
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_branch_config()
  t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), {
    stdout = "dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), {
    stdout = "dev",
    stderr = "",
    exit_code = 0,
  })
end


local function mock_pr_list(items)
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = numbered_list_json(items),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_state(comments, state)
  entity_read_mocks.mock_pr_read_forms(t, {
    repo = repo,
    number = 7,
    head = "devloop-owner-repo-42-01HY",
    head_sha = "def456",
    base_branch = "dev",
    state = state or "OPEN",
    updated_at = "2026-06-04T01:02:03Z",
    comments = comments,
    times = 1,
  })
end

local function mock_linked_pr_state(comments, state, exit_code, times, run_opts)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  local stderr = ""
  if exit_code ~= nil and exit_code ~= 0 then
    stderr = "pr view failed"
  end
  local stdout = string.format(
    '{"headRefName":"devloop-owner-repo-42-01HY","headRefOid":"def456","baseRefName":"dev","state":"%s","updatedAt":"2026-06-04T01:02:03Z","comments":[%s]}\n',
    json_string(state or "OPEN"),
    table.concat(rendered, ",")
  )
  entity_read_mocks.mock_pr_view_raw_selector(t, { repo = repo, number = 7 }, entity_read_mocks.pr_origin_selector, {
    stdout = stdout,
    stderr = stderr,
    exit_code = exit_code or 0,
  }, times or 1)
  if exit_code == nil or exit_code == 0 then
    h.run_department("departments/test_cache_seed/main.lua", { queue = "cache_seed", payload = { key = require("devloop.github_proxy_entity_view").entity_view_cache_key(repo, "pr", 7), value = '{"updated_at":"2026-06-04T01:02:03Z","producer":"observe_pr","stdout":"' .. json_string(stdout) .. '"}' } }, run_opts or opts("liveness-scan-linked-pr-cache-seed"))
    entity_read_mocks.mock_pr_read_forms(t, {
      repo = repo,
      number = 7,
      head = "devloop-owner-repo-42-01HY",
      head_sha = "def456",
      base_branch = "dev",
      state = state or "OPEN",
      updated_at = "2026-06-04T01:02:03Z",
      comments = comments,
      times = times or 1,
    })
  end
end

local function mock_linked_pr_absent(times)
  entity_read_mocks.mock_pr_view_raw_selector(t, { repo = repo, number = 7 }, entity_read_mocks.pr_origin_selector, {
    stdout = "",
    stderr = "HTTP 404: Not Found",
    exit_code = 1,
  }, times or 1)
end

local function assert_no_entity_change(result)
  t.eq(result.exit_code, 0)
  t.eq(find_raise(result.raises, ISSUE_REDRIVE_QUEUE), nil)
end

local function entity_change_issue_numbers(result)
  local numbers = {}
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == ISSUE_REDRIVE_QUEUE
      and raised.payload ~= nil
      and raised.payload.type == "issue" then
      numbers[tonumber(raised.payload.number)] = true
    end
  end
  return numbers
end

local function has_liveness_action_for_proposal(result, target_proposal_id)
  for _, raised in ipairs(result.raises or {}) do
    local payload = raised.payload or {}
    if payload.proposal_id == target_proposal_id
      or (raised.queue == ISSUE_REDRIVE_QUEUE
        and payload.type == "issue"
        and base_ids.proposal_id(payload.repo, payload.number) == target_proposal_id) then
      return true
    end
  end
  return false
end

local function timeout_state_comment(state_name, state_version, created_at)
  return {
    body = h.state_comment(proposal_id, state_name, state_version),
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end
local function recent_state_comment(state_name, state_version, seconds_ago)
  return timeout_state_comment(state_name, state_version, os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (seconds_ago or 60)))
end
local function ready_state_comment(comment_id, state_version, created_at)
  return { id = comment_id, body = h.projected_state_comment(proposal_id, "ready", state_version, "result-marker,ready-label,devloop-ready"), author_login = "fkst-test-bot", created_at = created_at or "2026-06-03T00:00:00Z" }
end
local function timeout_attempt_comment(state_name, state_version, round, created_at)
  return {
    body = conv_attempts.timeout_attempt_marker(proposal_id, state_version, state_name, round, entity_lib.issue_source_ref(repo, 42)),
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function timeout_attempt_v2_comment(row, generation_key, round, created_at)
  return {
    body = conv_attempts.timeout_attempt_v2_marker(proposal_id, row.from_state, row.liveness_class_id, generation_key, round, entity_lib.issue_source_ref(repo, 42)),
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function with_codex_runs(fn)
  local original = fkst.codex_runs
  local ok, err = pcall(fn)
  fkst.codex_runs = original
  if not ok then
    error(err)
  end
end

local function capture_timeout_raises_and_logs(fn)
  local raised = {}
  local logs = {}
  local original_log_raise = devloop_logging.log_raise
  local original_log_line = devloop_logging.log_line
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  devloop_logging.log_line = function(level, dept, proposal, tag, fields)
    table.insert(logs, { level = level, dept = dept, proposal = proposal, tag = tag, fields = fields })
  end
  local ok, err = pcall(fn)
  devloop_logging.log_raise = original_log_raise
  devloop_logging.log_line = original_log_line
  if not ok then
    error(err)
  end
  return raised, logs
end

local function captured_raise(raises, queue, predicate)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue
      and (predicate == nil or predicate(raised.payload, raised)) then
      return raised
    end
  end
  return nil
end

local function assert_no_observe_reinject(result)
  t.eq(find_raise(result.raises, ISSUE_REDRIVE_QUEUE), nil)
end

local function issue_rest_view_number(rendered)
  local text = tostring(rendered or "")
  return text:match("gh api 'repos/owner/repo/issues/(%d+)'$")
    or text:match("gh api repos/owner/repo/issues/(%d+)$")
end

return {
  base_ids = base_ids,
  h = h,
  entity_lib = entity_lib,
  devloop_base = devloop_base,
  devloop_logging = devloop_logging,
  cache_seed_helpers = cache_seed_helpers,
  contract_time = contract_time,
  conv_reconcile = conv_reconcile,
  conv_attempts = conv_attempts,
  m_rae = m_rae,
  t = t,
  core = core,
  opts = opts,
  decompose_lib = decompose_lib,
  issue = issue,
  mock_issue_state = mock_issue_state,
  run_observe = run_observe,
  find_raise = find_raise,
  render_comment = render_comment,
  json_string = json_string,
  ready = ready,
  replay_fields = replay_fields,
  mock_issue_reconcile = mock_issue_reconcile,
  entity_read_mocks = entity_read_mocks,
  codex_status = codex_status,
  m_builders = m_builders,
  ISSUE_REDRIVE_QUEUE = ISSUE_REDRIVE_QUEUE,
  _cache_seed_helpers = _cache_seed_helpers,
  restart_transition_row = restart_transition_row,
  run_timeout_reconcile = run_timeout_reconcile,
  repo = repo,
  proposal_id = proposal_id,
  version = version,
  recent_iso = recent_iso,
  run_liveness_scan = run_liveness_scan,
  run_liveness_scan_at = run_liveness_scan_at,
  mock_repo = mock_repo,
  numbered_list_json = numbered_list_json,
  blocked_by_json = blocked_by_json,
  mock_blocked_by = mock_blocked_by,
  mock_issue_list = mock_issue_list,
  mock_issue_state_number = mock_issue_state_number,
  mock_empty_pr_list = mock_empty_pr_list,
  mock_branch_config = mock_branch_config,
  mock_pr_list = mock_pr_list,
  mock_pr_state = mock_pr_state,
  mock_linked_pr_state = mock_linked_pr_state,
  mock_linked_pr_absent = mock_linked_pr_absent,
  assert_no_entity_change = assert_no_entity_change,
  entity_change_issue_numbers = entity_change_issue_numbers,
  has_liveness_action_for_proposal = has_liveness_action_for_proposal,
  timeout_state_comment = timeout_state_comment,
  recent_state_comment = recent_state_comment,
  ready_state_comment = ready_state_comment,
  timeout_attempt_comment = timeout_attempt_comment,
  timeout_attempt_v2_comment = timeout_attempt_v2_comment,
  with_codex_runs = with_codex_runs,
  capture_timeout_raises_and_logs = capture_timeout_raises_and_logs,
  captured_raise = captured_raise,
  assert_no_observe_reinject = assert_no_observe_reinject,
  issue_rest_view_number = issue_rest_view_number,
}
