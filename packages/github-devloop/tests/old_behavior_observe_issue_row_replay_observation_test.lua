local base_ids = require("devloop.base_ids")
local config = require("devloop.config")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local observation_support = require("testkit.old_behavior_observation_support")
local payloads_builders = require("devloop.payloads.builders")
local replayer = require("devloop.replayer")
local testing = require("testkit.testing")
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
local OBSERVATION_PREFIX = "row-replay:github-devloop:observe-issue/"
local SITE = {
  path = "packages/github-devloop/departments/observe_issue/main.lua",
  symbol = "replay_or_timeout",
  ordinal = "replayer.replay_from_table",
}

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = base_ids.proposal_id(REPO, ISSUE_NUMBER)
local UPDATED_AT = "2026-06-03T01:02:03Z"
local SOURCE_REF = { kind = "external", ref = "owner/repo#issue/42" }
local CONSENSUS_VERSION = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local IMPLEMENTING_VERSION = "ready/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local FIXTURES = json_array({
  { name = "route-thinking", state = "thinking", version_kind = "proposal", expected_status = "routed", expected_decision = "applied(replay)", expected_target = "consensus.proposal", expected_effect_ids = json_array({ "queue:consensus.proposal" }), expected_dispatched = true },
  { name = "route-dependency-wait", state = "dependency_wait", version = CONSENSUS_VERSION, dependency_wait = true, expected_status = "routed", expected_decision = "release-dependency-hold", expected_target = "ready", expected_effect_ids = json_array({ "comment:issue:row-replay", "comment:issue:row-replay", "label:issue:row-replay" }), expected_dispatched = true },
  { name = "route-ready", state = "ready", version = CONSENSUS_VERSION, ready_handoff = true, expected_status = "routed", expected_decision = "applied(replay)", expected_target = "implementing", expected_effect_ids = json_array({ "queue:devloop_ready" }), expected_dispatched = true },
  { name = "route-implementing", state = "implementing", version = IMPLEMENTING_VERSION, expected_status = "routed-noop", expected_decision = "skip-pending(no-implementing-fact)", expected_target = "devloop_ready", expected_effect_ids = json_array(), expected_dispatched = true },
  { name = "route-awaiting-pr", state = "awaiting-pr", version = IMPLEMENTING_VERSION, expected_status = "routed-noop", expected_decision = "skip-foreign(pr-delegation-missing)", expected_target = "awaiting-pr", expected_effect_ids = json_array(), expected_dispatched = true },
  { name = "route-impl-failed", state = "impl-failed", version = IMPLEMENTING_VERSION, expected_status = "routed-noop", expected_decision = "skip-idempotent(retry-limit)", expected_target = "implementing", expected_effect_ids = json_array(), expected_dispatched = true },
  { name = "route-blocked", state = "blocked", version = IMPLEMENTING_VERSION .. "/blocked", expected_status = "routed-noop", expected_decision = "skip-foreign(pr-link)", expected_target = "decomposed", expected_effect_ids = json_array(), expected_dispatched = true },
  { name = "skip-declined-terminal", state = "declined", version = CONSENSUS_VERSION .. "/declined", expected_status = "skip-terminal", expected_decision = "skip-terminal-row", expected_target = "declined", expected_effect_ids = json_array(), expected_dispatched = false },
  { name = "skip-merged-terminal", state = "merged", version = IMPLEMENTING_VERSION .. "/merged", expected_status = "skip-terminal", expected_decision = "skip-terminal-row", expected_target = "merged", expected_effect_ids = json_array(), expected_dispatched = false },
})

local function event_payload()
  return h.issue({
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture observe issue row replay routing",
    body = "",
    state = "OPEN",
    updated_at = UPDATED_AT,
    dedup_key = "owner/repo#issue#42@" .. UPDATED_AT,
    source_ref = copy_value(SOURCE_REF),
  })
end

local PROPOSAL_VERSION = payloads_builders.build_proposal(event_payload()).dedup_key

local function issue_event()
  return { queue = "github-proxy.github_entity_changed", ts = "2026-06-03T01:02:04Z", payload = event_payload() }
end

local function state_version(fixture)
  return fixture.version_kind == "proposal" and PROPOSAL_VERSION or fixture.version
end

local function trusted_comment(id, body, created_at)
  return { id = id, body = body, author_login = "fkst-test-bot", created_at = created_at or "2099-01-01T00:00:00Z" }
end

local function comments_for(fixture)
  local version = state_version(fixture)
  local effects = fixture.ready_handoff and "result-marker,ready-label,devloop-ready" or nil
  local comments = json_array({
    trusted_comment("IC_state_" .. fixture.state, core.state_marker(PROPOSAL_ID, fixture.state, version, effects)),
  })
  if fixture.dependency_wait then
    table.insert(comments, trusted_comment(
      "IC_dependency_wait",
      core.dependency_wait_marker(PROPOSAL_ID, version, { 53 }, "waiting", "waiting-on-dependency"),
      "2099-01-01T00:00:01Z"
    ))
  end
  return comments
end

local function labels_for(state)
  if state == "dependency_wait" then return { "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" } end
  return { "fkst-dev:enabled", "fkst-dev:" .. state }
end

local function prepare_fixture(fixture)
  h.mock_bot_env()
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture observe issue row replay routing",
    body = "",
    updated_at = UPDATED_AT,
    state = "OPEN",
    labels = labels_for(fixture.state),
    comments = comments_for(fixture),
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    created_at = "2026-06-01T00:00:00Z",
    times = 1,
  })
  if fixture.state == "thinking" then h.mock_context_bundle(event_payload()) end
  if fixture.state == "dependency_wait" or fixture.state == "ready" then
    t.mock_command(core.gh_blocked_by_cmd(REPO, ISSUE_NUMBER), {
      stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
  if fixture.state == "blocked" then
    t.mock_command(core.gh_issue_list_decompose_children_cmd(REPO, PROPOSAL_ID), {
      stdout = "[]\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function effect_id_for_queue(queue)
  if queue == "consensus.proposal" then return "queue:consensus.proposal", "queue" end
  if queue == "devloop_ready" then return "queue:devloop_ready", "queue" end
  if queue == "github-proxy.github_issue_comment_request" then return "comment:issue:row-replay", "comment" end
  if queue == "github-proxy.github_issue_label_request" then return "label:issue:row-replay", "label" end
  error("unclassified observe_issue row replay OLD raise: " .. tostring(queue), 0)
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
    local effect_id, sink_kind = effect_id_for_queue(raised.queue)
    table.insert(emitted, { effect_id = effect_id, sink_kind = sink_kind, authority_class = "lifecycle-authoritative", ordinal = ordinal })
    table.insert(writes, { effect_id = effect_id, queue = raised.queue, payload = copy_value(raised.payload) })
  end
  return emitted, writes
end

local function capture_runtime(fixture)
  local event = issue_event()
  prepare_fixture(fixture)
  local original_replay_from_table = replayer.replay_from_table
  local dispatch_calls = json_array()
  replayer.replay_from_table = function(M, dept, issue, state, row, facts)
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
    local replay_ok, issued = pcall(original_replay_from_table, M, dept, issue, state, row, facts)
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
      from_state = fixture.state,
      transition_kind = "versioned_transition_status",
      run = function() return testing.run_fake(observe_issue_department, event) end,
      codex_runs_for_read = json_array(),
      write_mode = "real",
    })
  end)
  replayer.replay_from_table = original_replay_from_table
  if not ok then error(result, 0) end

  local version = state_version(fixture)
  if fixture.expected_dispatched then
    t.eq(#dispatch_calls, 1, fixture.name .. ": nonterminal production row dispatch count")
    local dispatch = dispatch_calls[1]
    t.eq(dispatch.dept, "observe_issue", fixture.name .. ": production replay department")
    t.eq(dispatch.state, fixture.state, fixture.name .. ": production-derived replay state")
    t.eq(dispatch.version, version, fixture.name .. ": production-derived replay version")
    t.eq(dispatch.row_from_state, fixture.state, fixture.name .. ": production row identity")
    local row_decisions = json_array()
    for _, decision in ipairs(dispatch.decisions) do
      if decision.from_state == fixture.state then table.insert(row_decisions, decision) end
    end
    t.eq(
      #row_decisions,
      1,
      fixture.name .. ": one state-matched row routing disposition: " .. canonical_json(dispatch.decisions)
    )
    if fixture.state == "thinking" then
      t.eq(#dispatch.decisions, 2, "thinking route preserves the unmanaged idempotence prelude")
      t.eq(dispatch.decisions[1].outcome, "skip-idempotent(already at to_state)", "thinking prelude disposition")
    end
    dispatch.decision = row_decisions[1]
    t.eq(dispatch.decision.outcome, fixture.expected_decision, fixture.name .. ": exact routed decision")
    t.eq(dispatch.decision.to_state, fixture.expected_target, fixture.name .. ": exact routed target")
    t.eq(#dispatch.raises, #fixture.expected_effect_ids, fixture.name .. ": exact routed row-local effects")
    return event, captured, dispatch
  end
  t.eq(#dispatch_calls, 0, fixture.name .. ": terminal row is skipped before replay_from_table")
  return event, captured, {
    dept = "observe_issue",
    state = fixture.state,
    version = version,
    row_from_state = fixture.state,
    driving_queue = "none",
    decisions = json_array({ { from_state = fixture.state, outcome = "skip-terminal-row", to_state = fixture.state } }),
    decision = { from_state = fixture.state, outcome = "skip-terminal-row", to_state = fixture.state },
    raises = json_array(),
    applies = json_array(),
    issued = false,
  }
end

local function build_record(fixture)
  local event, captured, dispatch = capture_runtime(fixture)
  local emitted_effects, observable_writes = effect_observations(dispatch.raises)
  t.eq(canonical_json(effect_id_list(emitted_effects)), canonical_json(fixture.expected_effect_ids), fixture.name)
  local target_version = dispatch.raises[1] and dispatch.raises[1].payload.dedup_key or nil
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_PREFIX .. fixture.name,
    owner = "github-devloop",
    site = copy_value(SITE),
    boundary = "row_replay",
    typed_intent = {
      kind = "row_replay",
      source_state = fixture.state,
      source_boundary = event.queue,
      target = fixture.expected_target,
      cause_schema_id = event.payload.schema,
      generation_epoch = { state_version = dispatch.version, replay_version = nullable(target_version), terminal = not fixture.expected_dispatched },
      lineage = { proposal_id = PROPOSAL_ID, issue_number = ISSUE_NUMBER, source_ref = copy_value(SOURCE_REF), state_version = dispatch.version },
    },
    old_inputs = {
      current_fact = { state = dispatch.state, version = dispatch.version, stage_rank = devloop_state.stage_rank(dispatch.state) },
      caller_from_states = json_array({ fixture.state }),
      incoming_version = dispatch.version,
      target_version = nullable(target_version),
      handoff_reference = JSON_NULL,
    },
    old_outcome = {
      status = fixture.expected_status,
      reason_code = fixture.expected_decision,
      cas_outcome = dispatch.decision.outcome,
      emitted_effects = emitted_effects,
      observable_writes = observable_writes,
      handoff_direct_lookup_count = captured.handoff_direct_lookup_count,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      { kind = "runtime-row-replay-router", ref = "packages/github-devloop/departments/observe_issue/main.lua:139-190" },
      { kind = "runtime-row-table", ref = "libraries/devloop/restart/issue_observation_facts.lua:1-59" },
      { kind = "runtime-disposition", ref = fixture.expected_dispatched and ("devloop.logging.log_cas_decision:observe_issue:" .. fixture.expected_decision) or "replay_or_timeout:terminal-row-no-dispatch" },
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
    local value = tuple(fixture.name, fixture.expected_status, fixture.expected_decision, fixture.expected_target, fixture.expected_effect_ids)
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

local function assert_row_universe_is_production_declared()
  local declared = {}
  for _, row in ipairs(core.restart_transition_table()) do declared[row.from_state] = row end
  t.eq(#FIXTURES, #core.restart_transition_table(), "router fixtures equal production restart row count")
  for _, fixture in ipairs(FIXTURES) do
    local row = declared[fixture.state]
    t.is_true(row ~= nil, fixture.name .. ": fixture state is production-declared")
    t.eq(row.terminal == true, not fixture.expected_dispatched, fixture.name .. ": terminal status determines dispatch")
  end
end

return {
  test_observe_issue_row_replay_old_behavior_is_real_dispatch_and_bidirectional = function()
    assert_row_universe_is_production_declared()
    local fixtures = fixture_tuple_set()
    local first = capture_records()
    local second = capture_records()
    t.eq(#first, 9, "complete production-reachable observe_issue replay router disposition count")
    local repeat_difference = first_difference(second, first, "old_behavior_observations[observe-issue-row-replay][repeat]")
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then error("second OLD observe_issue row replay capture differs at " .. tostring(repeat_difference or "canonical-json"), 0) end
    local runtime_tuples = record_tuple_set(first, "runtime records")
    assert_bidirectional(runtime_tuples, fixtures, "runtime records", "production fixture lattice", first)
    local expected = committed_records()
    assert_bidirectional(runtime_tuples, record_tuple_set(expected, "inventory records"), "runtime records", "inventory records", first)
    local difference = first_difference(first, expected, "old_behavior_observations[observe-issue-row-replay]")
    if difference ~= nil or canonical_json(first) ~= canonical_json(expected) then error("runtime-bound OLD observe_issue row replay observation differs at " .. tostring(difference or "canonical-json") .. "; runtime_records=" .. canonical_json(first), 0) end

    local drifted = copy_value(first)
    drifted[1].old_outcome.emitted_effects = {}
    local root = "old_behavior_observations[observe-issue-row-replay][negative_control]"
    local drift = first_difference(drifted, first, root)
    t.is_true(canonical_json(drifted) ~= canonical_json(first), "empty array to object drift changes JSON")
    t.is_true(drift ~= nil and drift:find(root .. ".1.old_outcome.emitted_effects", 1, true) ~= nil, tostring(drift))
  end,
}
