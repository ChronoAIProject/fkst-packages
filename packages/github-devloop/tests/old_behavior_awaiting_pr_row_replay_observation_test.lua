local autonomy_ledger = require("devloop.autonomy_ledger")
local config = require("devloop.config")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local github_commands = require("forge.github").new(function() end)
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit.old_behavior_observation_support")
local replayer = require("devloop.replayer")
local testing = require("testkit.testing")
local transition_version = require("contract.transition_version")
local observe_issue_department = require("departments.observe_issue.main")

local t = h.t
local core = h.core
local JSON_NULL = observation_support.JSON_NULL
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local nullable = observation_support.nullable
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local OBSERVATION_PREFIX = "row-replay:github-devloop:awaiting-pr/"
local SITE = {
  path = "packages/github-devloop/core/awaiting_pr_replayer.lua",
  symbol = "M.replay_awaiting_pr_state",
  ordinal = "row-replay/awaiting-pr",
}

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local OTHER_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local INTEGRATION_BRANCH = "integration/dev"
local UPSTREAM_BRANCH = "dev"
local OTHER_BASE_BRANCH = "integration/other"
local HEAD_SHA = "0123456789abcdef0123456789abcdef01234567"
local MERGE_COMMIT_SHA = "1111111111111111111111111111111111111111"
local SOURCE_REF = entity_lib.issue_source_ref(REPO, ISSUE_NUMBER)
local ORIGINAL_BRANCH = devloop_base.implement_branch(REPO, ISSUE_NUMBER, core.implementation_base_version(VERSION))
local REPLACEMENT_VERSION = transition_version.reimplement_at(core.implementation_base_version(VERSION), 1)
local REPLACEMENT_BRANCH = devloop_base.implement_branch(REPO, ISSUE_NUMBER, REPLACEMENT_VERSION)

local FIXTURES = json_array({
  { name = "pr-delegation-missing", delegation = false, expected_status = "skip-foreign", expected_disposition = "skip-foreign(pr-delegation-missing)" },
  { name = "pr-delegation-child", pr_number = 9800, child_repo = "other/repo", child_marker = false, expected_status = "skip-stale", expected_disposition = "skip-stale(pr-delegation-child)" },
  { name = "child-terminal-missing", pr_number = 9801, child_marker = false, expected_status = "skip-pending", expected_disposition = "skip-pending(child-terminal-missing)" },
  { name = "child-nonterminal", pr_number = 9802, child_state = "reviewing", expected_status = "skip-pending", expected_disposition = "skip-pending(child-nonterminal)" },
  { name = "child-state-lineage", pr_number = 9803, child_state = "blocked", child_version = OTHER_VERSION, expected_status = "skip-stale", expected_disposition = "skip-stale(child-state-lineage)" },
  { name = "child-branch-lineage", pr_number = 9804, child_state = "closed-unmerged", branch = "unexpected-child-branch", pr_state = "CLOSED", expected_status = "skip-stale", expected_disposition = "skip-stale(child-branch-lineage)" },
  { name = "canonical-child-pr-merged-missing", pr_number = 9805, child_state = "merged", pr_state = "OPEN", expected_status = "skip-pending", expected_disposition = "skip-pending(canonical-child-pr-merged-missing)" },
  { name = "pr-origin-rollup-lineage", pr_number = 9806, child_state = "merged", pr_state = "MERGED", base_branch = OTHER_BASE_BRANCH, expected_status = "skip-stale", expected_disposition = "skip-stale(pr-origin-rollup-lineage)" },
  { name = "merge-commit-missing", pr_number = 9807, child_state = "merged", pr_state = "MERGED", merge_commit_sha = "", expected_status = "skip-pending", expected_disposition = "skip-pending(merge-commit-missing)" },
  { name = "rollup-receipt-missing", pr_number = 9808, child_state = "merged", pr_state = "MERGED", rollup_receipt_missing = true, expected_status = "skip-pending", expected_disposition = "skip-pending(rollup-receipt-missing)" },
  { name = "child-pr-merged", pr_number = 9810, child_state = "merged", pr_state = "MERGED", base_branch = UPSTREAM_BRANCH, unified_branches = true, expected_target = "merged", expected_status = "route-to-terminal", expected_disposition = "applied(child-pr-merged)", expected_effect_ids = json_array({ "comment:issue:awaiting-pr-terminal", "label:issue:awaiting-pr-terminal" }), expected_ledger_calls = 1 },
  { name = "child-pr-closed-unmerged", pr_number = 9811, child_state = "closed-unmerged", branch = ORIGINAL_BRANCH, pr_state = "CLOSED", expected_target = "ready", expected_status = "route-to-replacement", expected_disposition = "applied(child-pr-closed-unmerged)", expected_effect_ids = json_array({ "comment:issue:awaiting-pr-terminal", "label:issue:awaiting-pr-terminal" }) },
  { name = "replacement-budget-exhausted", pr_number = 9812, child_state = "closed-unmerged", branch = REPLACEMENT_BRANCH, pr_state = "CLOSED", expected_target = "blocked", expected_status = "route-to-terminal", expected_disposition = "applied(replacement-budget-exhausted)", expected_effect_ids = json_array({ "comment:issue:awaiting-pr-terminal", "label:issue:awaiting-pr-terminal" }) },
  { name = "child-pr-blocked", pr_number = 9813, child_state = "blocked", expected_target = "blocked", expected_status = "route-to-terminal", expected_disposition = "applied(child-pr-blocked)", expected_effect_ids = json_array({ "comment:issue:awaiting-pr-terminal", "label:issue:awaiting-pr-terminal" }) },
})

local function trusted_comment(body, created_at)
  return { body = body, author_login = "fkst-test-bot", created_at = created_at or "2099-01-01T00:00:00Z" }
end

local function child_proposal_id(fixture)
  return entity_lib.pr_proposal_id(fixture.child_repo or REPO, fixture.pr_number or 7)
end

local function next_state_version(fixture)
  if fixture.name == "child-pr-closed-unmerged" then return REPLACEMENT_VERSION end
  if fixture.name == "replacement-budget-exhausted" then return VERSION .. "/blocked/replacement-budget-exhausted" end
  if fixture.expected_target == "blocked" then return VERSION .. "/blocked/child-pr-blocked" end
  return VERSION
end

local function parent_comments(fixture)
  local comments = json_array({ trusted_comment(core.state_marker(PROPOSAL_ID, "awaiting-pr", VERSION)) })
  if fixture.delegation ~= false then
    table.insert(comments, trusted_comment(m_builders.pr_delegation_marker(
      PROPOSAL_ID,
      child_proposal_id(fixture),
      fixture.pr_number or 7,
      fixture.delegation_version or VERSION,
      "g1"
    ), "2099-01-01T00:00:01Z"))
  end
  return comments
end

local function child_comments(fixture)
  local comments = json_array({
    trusted_comment(m_builders.pr_origin_marker(
      PROPOSAL_ID,
      ISSUE_NUMBER,
      fixture.branch or ORIGINAL_BRANCH,
      VERSION,
      fixture.base_branch or INTEGRATION_BRANCH
    ), "2026-06-03T01:03:00Z"),
  })
  if fixture.child_marker ~= false then
    table.insert(comments, trusted_comment(core.state_marker(
      PROPOSAL_ID,
      fixture.child_state,
      fixture.child_version or VERSION
    ), "2026-06-03T01:04:00Z"))
  end
  return comments
end

local function event_payload(fixture)
  return h.issue({
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture awaiting PR row replay behavior",
    body = "",
    state = "OPEN",
    updated_at = "2026-06-03T02:03:04Z",
    dedup_key = "owner/repo#issue#42@2026-06-03T02:03:04Z/" .. fixture.name,
    source_ref = copy_value(SOURCE_REF),
  })
end

local function issue_event(fixture)
  return { queue = "github-proxy.github_entity_changed", ts = "2026-06-03T02:03:05Z", payload = event_payload(fixture) }
end

local function fake_autonomy_record(merge_ready, fixture)
  return {
    schema = "github-devloop.autonomy-result.v1",
    proposal_id = tostring(merge_ready.proposal_id),
    repo = REPO,
    issue_number = tostring(ISSUE_NUMBER),
    pr_number = tostring(merge_ready.pr_number),
    version = tostring(merge_ready.version),
    head_sha = tostring(merge_ready.reviewed_head_sha),
    merged_at = fixture.pr_state == "MERGED" and "2026-06-03T02:05:04Z" or nil,
    task_class = "L1",
    human_touch_count = 0,
    pre_merge_ci = "pass",
    rounds = 0,
    retry_count = 0,
    codex_calls = nil,
    gates = { human_touch = "pass", pre_merge_ci = "pass", evidence_manifest = "pending", post_merge_probe = "pending", no_revert_reopen = "pending", cost_budget = "pending" },
    valid_autonomous_merge = "pending",
  }
end

local function prepare_fixture(fixture)
  h.mock_bot_env()
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture awaiting PR row replay behavior",
    body = "",
    updated_at = "2026-06-03T02:03:04Z",
    state = "OPEN",
    labels = { "fkst-dev:enabled", "fkst-dev:awaiting-pr" },
    comments = parent_comments(fixture),
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    created_at = "2026-06-01T00:00:00Z",
    times = 1,
  })
  if fixture.pr_number ~= nil then
    entity_read_mocks.mock_pr_read_forms(t, {
      repo = REPO,
      number = fixture.pr_number,
      comments = child_comments(fixture),
      head = fixture.branch or ORIGINAL_BRANCH,
      head_sha = HEAD_SHA,
      merge_commit_sha = fixture.merge_commit_sha ~= nil and fixture.merge_commit_sha or MERGE_COMMIT_SHA,
      state = fixture.pr_state or "OPEN",
      merged_at = fixture.pr_state == "MERGED" and "2026-06-03T02:05:04Z" or nil,
      base_branch = fixture.base_branch or INTEGRATION_BRANCH,
      labels = {},
      status_check_rollup_json = "[]",
      register_all_views = true,
      times = 1,
    })
  end
  if fixture.rollup_receipt_missing then
    t.mock_command(github_commands.pr_list_promotions_cmd(REPO, INTEGRATION_BRANCH, UPSTREAM_BRANCH), {
      stdout = "[[]]\n", stderr = "", exit_code = 0,
    })
  end
  if fixture.name == "child-pr-merged" then
    t.mock_command("gh issue close", { stdout = "closed\n", stderr = "", exit_code = 0 })
  end
end

local function effect_id_list(effects)
  local ids = json_array()
  for _, effect in ipairs(effects or {}) do table.insert(ids, tostring(effect.effect_id)) end
  return ids
end

local function effect_observations(raises)
  local emitted = json_array()
  local writes = json_array()
  for ordinal, raised in ipairs(raises) do
    local effect_id
    local sink_kind
    if raised.queue == "github-proxy.github_issue_comment_request" then
      effect_id, sink_kind = "comment:issue:awaiting-pr-terminal", "comment"
    elseif raised.queue == "github-proxy.github_issue_label_request" then
      effect_id, sink_kind = "label:issue:awaiting-pr-terminal", "label"
    else
      error("unclassified awaiting-pr row replay OLD raise: " .. tostring(raised.queue), 0)
    end
    table.insert(emitted, { effect_id = effect_id, sink_kind = sink_kind, authority_class = "lifecycle-authoritative", ordinal = ordinal })
    table.insert(writes, { effect_id = effect_id, queue = raised.queue, payload = copy_value(raised.payload) })
  end
  return emitted, writes
end

local function capture_runtime(fixture)
  local event = issue_event(fixture)
  prepare_fixture(fixture)
  local original_branch_config = config.branch_config
  local original_autonomy_result_record = autonomy_ledger.autonomy_result_record
  local original_handler = core.replayer_registry["awaiting-pr"]
  local dispatch_calls = json_array()
  local ledger_calls = 0
  config.branch_config = function()
    return { integration = fixture.unified_branches and UPSTREAM_BRANCH or INTEGRATION_BRANCH, upstream = UPSTREAM_BRANCH }
  end
  autonomy_ledger.autonomy_result_record = function(_, repo, issue_number, merge_ready)
    ledger_calls = ledger_calls + 1
    t.eq(repo, REPO, fixture.name .. ": autonomy repo")
    t.eq(issue_number, ISSUE_NUMBER, fixture.name .. ": autonomy issue")
    return fake_autonomy_record(merge_ready, fixture)
  end
  core.replayer_registry["awaiting-pr"] = function(dept, issue, state, row, facts)
    local dispatch = {
      dept = dept,
      state = state and state.state,
      version = state and state.version,
      row_from_state = row and row.from_state,
      driving_queue = row and row.driving_queue,
      decisions = json_array(),
      raises = json_array(),
      applies = json_array(),
    }
    local active_log_decision = devloop_logging.log_cas_decision
    local active_log_raise = devloop_logging.log_raise
    local active_log_apply = devloop_logging.log_apply
    devloop_logging.log_cas_decision = function(log_dept, proposal_id, current, from_state, to_state, outcome, reason)
      table.insert(dispatch.decisions, { proposal_id = proposal_id, from_state = from_state, to_state = to_state, outcome = outcome, reason = reason })
      return active_log_decision(log_dept, proposal_id, current, from_state, to_state, outcome, reason)
    end
    devloop_logging.log_raise = function(log_dept, proposal_id, queue, payload)
      table.insert(dispatch.raises, { proposal_id = proposal_id, queue = queue, payload = copy_value(payload) })
      return active_log_raise(log_dept, proposal_id, queue, payload)
    end
    devloop_logging.log_apply = function(log_dept, proposal_id, to_state, version, labels, queues)
      table.insert(dispatch.applies, { proposal_id = proposal_id, to_state = to_state, version = version, labels = copy_value(labels), queues = copy_value(queues) })
      return active_log_apply(log_dept, proposal_id, to_state, version, labels, queues)
    end
    local replay_ok, issued = pcall(original_handler, dept, issue, state, row, facts)
    devloop_logging.log_apply = active_log_apply
    devloop_logging.log_raise = active_log_raise
    devloop_logging.log_cas_decision = active_log_decision
    if not replay_ok then error(issued, 0) end
    dispatch.issued = issued == true
    table.insert(dispatch_calls, dispatch)
    return issued
  end

  local ok, result, captured = pcall(function()
    return observation_support.observe_department({
      config = config,
      devloop_logging = devloop_logging,
      devloop_state = devloop_state,
      dept = "observe_issue",
      from_state = "awaiting-pr",
      transition_kind = "versioned_transition_status",
      run = function() return testing.run_fake(observe_issue_department, event) end,
      codex_runs_for_read = json_array(),
      write_mode = "real",
    })
  end)
  core.replayer_registry["awaiting-pr"] = original_handler
  autonomy_ledger.autonomy_result_record = original_autonomy_result_record
  config.branch_config = original_branch_config
  if not ok then error(result, 0) end

  t.eq(#dispatch_calls, 1, fixture.name .. ": real observe_issue dispatch reaches awaiting-pr handler once")
  local dispatch = dispatch_calls[1]
  local expected_target = fixture.expected_target or "awaiting-pr"
  local expected_effect_ids = fixture.expected_effect_ids or json_array()
  t.eq(dispatch.dept, "observe_issue", fixture.name .. ": production replay department")
  t.eq(dispatch.state, "awaiting-pr", fixture.name .. ": production-derived replay state")
  t.eq(dispatch.version, VERSION, fixture.name .. ": production-derived replay version")
  t.eq(dispatch.row_from_state, "awaiting-pr", fixture.name .. ": production awaiting-pr row")
  t.eq(dispatch.driving_queue, "devloop_observe_redrive", fixture.name .. ": production driving queue")
  t.eq(#dispatch.decisions, 1, fixture.name .. ": one row-local replay disposition")
  t.eq(dispatch.decisions[1].outcome, fixture.expected_disposition, fixture.name .. ": exact replay decision")
  t.eq(dispatch.decisions[1].to_state, expected_target, fixture.name .. ": exact replay target")
  t.eq(#dispatch.raises, #expected_effect_ids, fixture.name .. ": row-local effect count")
  t.eq(ledger_calls, fixture.expected_ledger_calls or 0, fixture.name .. ": autonomy ledger call count")
  return event, captured, dispatch
end

local function build_record(fixture)
  local event, captured, dispatch = capture_runtime(fixture)
  local expected_target = fixture.expected_target or "awaiting-pr"
  local expected_effect_ids = fixture.expected_effect_ids or json_array()
  local emitted_effects, observable_writes = effect_observations(dispatch.raises)
  t.eq(canonical_json(effect_id_list(emitted_effects)), canonical_json(expected_effect_ids), fixture.name)
  local target_version = fixture.expected_target and next_state_version(fixture) or nil
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_PREFIX .. fixture.name,
    owner = "github-devloop",
    site = copy_value(SITE),
    boundary = "row_replay",
    typed_intent = {
      kind = "row_replay",
      source_state = "awaiting-pr",
      source_boundary = event.queue,
      target = expected_target,
      cause_schema_id = event.payload.schema,
      generation_epoch = { state_version = VERSION, replay_version = nullable(target_version), delegation = fixture.delegation == false and JSON_NULL or "g1" },
      lineage = { proposal_id = PROPOSAL_ID, issue_number = ISSUE_NUMBER, pr_number = nullable(fixture.pr_number), source_ref = copy_value(SOURCE_REF), state_version = VERSION },
    },
    old_inputs = {
      current_fact = { state = "awaiting-pr", version = VERSION, stage_rank = devloop_state.stage_rank("awaiting-pr") },
      caller_from_states = json_array({ "awaiting-pr" }),
      incoming_version = VERSION,
      target_version = nullable(target_version),
      handoff_reference = JSON_NULL,
    },
    old_outcome = {
      status = fixture.expected_status,
      reason_code = fixture.expected_disposition,
      cas_outcome = dispatch.decisions[1].outcome,
      emitted_effects = emitted_effects,
      observable_writes = observable_writes,
      handoff_direct_lookup_count = captured.handoff_direct_lookup_count,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      { kind = "runtime-row-replay-dispatch", ref = "packages/github-devloop/departments/observe_issue/main.lua:179-183" },
      { kind = "runtime-row-replay-handler", ref = "packages/github-devloop/core/awaiting_pr_replayer.lua:333-426" },
      { kind = "runtime-disposition", ref = "devloop.logging.log_cas_decision:observe_issue:" .. dispatch.decisions[1].outcome },
      { kind = "runtime-event-source", ref = event.payload.source_ref.ref },
    }),
  }
end

local function tuple(variant, status, reason, target, effects)
  return table.concat({ variant, status, reason, target, table.concat(effects, ",") }, "|")
end

local function fixture_tuple_set()
  local tuples = {}
  for _, fixture in ipairs(FIXTURES) do
    local value = tuple(fixture.name, fixture.expected_status, fixture.expected_disposition, fixture.expected_target or "awaiting-pr", fixture.expected_effect_ids or json_array())
    if tuples[value] ~= nil then error("duplicate production fixture tuple: " .. value, 0) end
    tuples[value] = true
  end
  return tuples
end

local function record_tuple_set(records, label)
  local tuples = {}
  for _, record in ipairs(records) do
    local observation_id = tostring(record.observation_id or "")
    if observation_id:sub(1, #OBSERVATION_PREFIX) ~= OBSERVATION_PREFIX then error(label .. " has unexpected observation_id " .. observation_id, 0) end
    local value = tuple(observation_id:sub(#OBSERVATION_PREFIX + 1), tostring(record.old_outcome.status or ""), tostring(record.old_outcome.reason_code or ""), tostring(record.typed_intent.target or ""), effect_id_list(record.old_outcome.emitted_effects))
    if tuples[value] ~= nil then error(label .. " contains duplicate tuple: " .. value, 0) end
    tuples[value] = true
  end
  return tuples
end

local function assert_bidirectional(actual, expected, actual_label, expected_label, records)
  for value in pairs(actual) do if expected[value] == nil then error(actual_label .. " tuple absent from " .. expected_label .. ": " .. value .. "; records=" .. canonical_json(records), 0) end end
  for value in pairs(expected) do if actual[value] == nil then error(expected_label .. " tuple absent from " .. actual_label .. ": " .. value .. "; records=" .. canonical_json(records), 0) end end
end

local function capture_records()
  local records = json_array()
  for _, fixture in ipairs(FIXTURES) do table.insert(records, build_record(fixture)) end
  table.sort(records, function(left, right) return left.observation_id < right.observation_id end)
  return records
end

local function committed_records()
  local selected = json_array()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    local site = record.site
    if type(site) == "table" and site.path == SITE.path and site.symbol == SITE.symbol and site.ordinal == SITE.ordinal then table.insert(selected, record) end
  end
  table.sort(selected, function(left, right) return left.observation_id < right.observation_id end)
  return selected
end

local function assert_exact_target_marker_skew_is_not_production_reachable()
  for _, fixture in ipairs(FIXTURES) do
    if fixture.expected_target ~= nil then
      local comments = parent_comments(fixture)
      table.insert(comments, trusted_comment(core.state_marker(PROPOSAL_ID, fixture.expected_target, next_state_version(fixture)), "2099-01-01T00:00:02Z"))
      local derived = devloop_state.current_state(comments, PROPOSAL_ID)
      t.eq(derived.state, fixture.expected_target, fixture.name .. ": visible target marker changes production-derived state before replay")
    end
  end
end

return {
  test_awaiting_pr_row_replay_old_behavior_is_real_dispatch_and_bidirectional = function()
    assert_exact_target_marker_skew_is_not_production_reachable()
    local fixtures = fixture_tuple_set()
    local first = capture_records()
    local second = capture_records()
    t.eq(#first, 14, "complete production-reachable awaiting-pr replay disposition count")
    local repeat_difference = first_difference(second, first, "old_behavior_observations[awaiting-pr-row-replay][repeat]")
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then error("second OLD awaiting-pr row replay capture differs at " .. tostring(repeat_difference or "canonical-json"), 0) end
    local runtime_tuples = record_tuple_set(first, "runtime records")
    assert_bidirectional(runtime_tuples, fixtures, "runtime records", "production fixture lattice", first)
    local expected = committed_records()
    assert_bidirectional(runtime_tuples, record_tuple_set(expected, "inventory records"), "runtime records", "inventory records", first)
    local difference = first_difference(first, expected, "old_behavior_observations[awaiting-pr-row-replay]")
    if difference ~= nil or canonical_json(first) ~= canonical_json(expected) then error("runtime-bound OLD awaiting-pr row replay observation differs at " .. tostring(difference or "canonical-json") .. "; runtime_records=" .. canonical_json(first), 0) end

    local drifted = copy_value(first)
    drifted[1].old_outcome.emitted_effects = {}
    local root = "old_behavior_observations[awaiting-pr-row-replay][negative_control]"
    local drift = first_difference(drifted, first, root)
    t.is_true(canonical_json(drifted) ~= canonical_json(first), "empty array to object drift changes JSON")
    t.is_true(drift ~= nil and drift:find(root .. ".1.old_outcome.emitted_effects", 1, true) ~= nil, tostring(drift))
  end,
}
