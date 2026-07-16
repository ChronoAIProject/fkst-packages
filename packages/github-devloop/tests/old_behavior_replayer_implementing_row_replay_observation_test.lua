local base_ids = require("devloop.base_ids")
local config = require("devloop.config")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit.old_behavior_observation_support")
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
local OBSERVATION_PREFIX = "row-replay:github-devloop:replayer-implementing/"
local SITE = {
  path = "libraries/devloop/replayer.lua",
  symbol = "replay_implementing",
  ordinal = "row-replay/implementing",
}

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = base_ids.proposal_id(REPO, ISSUE_NUMBER)
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local UPDATED_AT = "2026-06-03T01:02:03Z"
local SOURCE_REF = { kind = "external", ref = "owner/repo#issue/42" }
local BRANCH = "devloop-owner-repo-42-row-replay"
local HEAD_SHA = "0123456789abcdef0123456789abcdef01234567"

local FIXTURES = json_array({
  {
    name = "no-progress-fact-noop",
    expected_status = "no-op",
    expected_reason = "no-implementing-progress-fact",
    expected_decision = "skip-pending(no-implementing-fact)",
    expected_target = "devloop_ready",
    expected_effect_ids = json_array(),
    expected_issued = false,
  },
  {
    name = "matching-live-run-defer",
    implementing_fact = true,
    live_run = true,
    expected_status = "deferred",
    expected_reason = "matching-implement-codex-run-live",
    expected_decision = "skip-pending(codex-run-live)",
    expected_target = "devloop_ready",
    expected_effect_ids = json_array(),
    expected_issued = false,
  },
  {
    name = "fresh-progress-budget-noop",
    implementing_fact = true,
    marker_created_at = "2099-01-01T00:00:00Z",
    expected_status = "no-op",
    expected_reason = "implementing-progress-within-row-budget",
    expected_decision = "skip-pending(liveness-budget)",
    expected_target = "devloop_ready",
    expected_effect_ids = json_array(),
    expected_issued = false,
  },
  {
    name = "absent-run-redrive",
    attempt = 1,
    attempt_started_at = "2000-01-01T00:00:00Z",
    marker_created_at = "2000-01-01T00:00:00Z",
    expected_status = "re-raised",
    expected_reason = "matching-implement-codex-run-absent",
    expected_decision = "applied(codex-run-absent)",
    expected_target = "implementing",
    expected_effect_ids = json_array({ "queue:devloop_ready" }),
    expected_issued = true,
  },
})

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2000-01-01T00:00:00Z",
  }
end

local function event_payload()
  return h.issue({
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture implementing row replay behavior",
    body = "",
    state = "OPEN",
    updated_at = UPDATED_AT,
    dedup_key = "owner/repo#issue#42@" .. UPDATED_AT,
    source_ref = copy_value(SOURCE_REF),
  })
end


local function issue_event()
  return {
    queue = "github-proxy.github_entity_changed",
    ts = "2026-06-03T01:02:04Z",
    payload = event_payload(),
  }
end

local function comments_for(fixture)
  local created_at = fixture.marker_created_at or "2000-01-01T00:00:00Z"
  local comments = json_array({
    trusted_comment(core.state_marker(PROPOSAL_ID, "implementing", VERSION), created_at),
  })
  if fixture.implementing_fact then
    table.insert(comments, trusted_comment(m_builders.implementing_marker(
      PROPOSAL_ID,
      VERSION,
      BRANCH,
      HEAD_SHA,
      "dev",
      HEAD_SHA
    ), created_at))
  end
  if fixture.attempt ~= nil then
    table.insert(comments, trusted_comment(core.implement_attempt_marker(
      PROPOSAL_ID,
      VERSION,
      fixture.attempt,
      fixture.attempt_started_at
    ), created_at))
  end
  return comments
end

local function controlled_codex_runs(fixture)
  if not fixture.live_run then return json_array() end
  return json_array({
    {
      run_id = "implementing-row-replay-live",
      role = "implement",
      proposal_id = PROPOSAL_ID,
      dedup_key = VERSION,
      status = "running",
      started_at = "2099-01-01T00:00:00Z",
      timeout_seconds = 3600,
    },
  })
end

local function prepare_fixture(fixture)
  h.mock_bot_env()
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture implementing row replay behavior",
    body = "",
    updated_at = UPDATED_AT,
    state = "OPEN",
    labels = { "fkst-dev:enabled", "fkst-dev:implementing" },
    comments = comments_for(fixture),
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    created_at = "2026-06-01T00:00:00Z",
    times = 1,
  })
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
    if raised.queue ~= "devloop_ready" then
      error("unclassified implementing row replay OLD raise: " .. tostring(raised.queue), 0)
    end
    table.insert(emitted, {
      effect_id = "queue:devloop_ready",
      sink_kind = "queue",
      authority_class = "lifecycle-authoritative",
      ordinal = ordinal,
    })
    table.insert(writes, {
      effect_id = "queue:devloop_ready",
      queue = raised.queue,
      payload = copy_value(raised.payload),
    })
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
      table.insert(dispatch.decisions, {
        proposal_id = proposal_id,
        from_state = from_state,
        to_state = to_state,
        outcome = outcome,
        reason = reason,
      })
      return active_log_decision(log_dept, proposal_id, current, from_state, to_state, outcome, reason)
    end
    devloop_logging.log_raise = function(log_dept, proposal_id, queue, payload)
      table.insert(dispatch.raises, { proposal_id = proposal_id, queue = queue, payload = copy_value(payload) })
      return active_log_raise(log_dept, proposal_id, queue, payload)
    end
    devloop_logging.log_apply = function(log_dept, proposal_id, to_state, version, labels, queues)
      table.insert(dispatch.applies, {
        proposal_id = proposal_id,
        to_state = to_state,
        version = version,
        labels = copy_value(labels),
        queues = copy_value(queues),
      })
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
      from_state = "implementing",
      transition_kind = "versioned_transition_status",
      run = function() return testing.run_fake(observe_issue_department, event) end,
      codex_runs_for_read = controlled_codex_runs(fixture),
      write_mode = "real",
    })
  end)
  replayer.replay_from_table = original_replay_from_table
  if not ok then error(result, 0) end

  t.eq(#dispatch_calls, 1, fixture.name .. ": real observe_issue dispatch reaches replay_from_table once")
  local dispatch = dispatch_calls[1]
  t.eq(dispatch.dept, "observe_issue", fixture.name .. ": production replay department")
  t.eq(dispatch.state, "implementing", fixture.name .. ": production-derived replay state")
  t.eq(dispatch.version, VERSION, fixture.name .. ": production-derived replay version")
  t.eq(dispatch.row_from_state, "implementing", fixture.name .. ": production implementing row")
  t.eq(dispatch.driving_queue, "devloop_ready", fixture.name .. ": production driving queue")
  t.eq(dispatch.issued, fixture.expected_issued, fixture.name .. ": exact row replay return disposition")
    t.eq(
      #dispatch.decisions,
      1,
      fixture.name .. ": one row-local replay disposition: " .. canonical_json(dispatch.decisions)
    )
  t.eq(dispatch.decisions[1].outcome, fixture.expected_decision, fixture.name .. ": exact replay decision")
  t.eq(dispatch.decisions[1].to_state, fixture.expected_target, fixture.name .. ": exact replay target")
  t.eq(#dispatch.raises, #fixture.expected_effect_ids, fixture.name .. ": row-local effect count")
  return event, captured, dispatch
end

local function build_record(fixture)
  local event, captured, dispatch = capture_runtime(fixture)
  local emitted_effects, observable_writes = effect_observations(dispatch.raises)
  t.eq(canonical_json(effect_id_list(emitted_effects)), canonical_json(fixture.expected_effect_ids), fixture.name)
  local replay_version = dispatch.raises[1] and dispatch.raises[1].payload.dedup_key or nil
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_PREFIX .. fixture.name,
    owner = "github-devloop",
    site = copy_value(SITE),
    boundary = "row_replay",
    typed_intent = {
      kind = "row_replay",
      source_state = "implementing",
      source_boundary = event.queue,
      target = fixture.expected_target,
      cause_schema_id = event.payload.schema,
      generation_epoch = {
        state_version = dispatch.version,
        replay_version = nullable(replay_version),
        implement_attempt = nullable(fixture.attempt),
      },
      lineage = {
        proposal_id = PROPOSAL_ID,
        issue_number = ISSUE_NUMBER,
        source_ref = copy_value(SOURCE_REF),
        state_version = dispatch.version,
      },
    },
    old_inputs = {
      current_fact = {
        state = dispatch.state,
        version = dispatch.version,
        stage_rank = devloop_state.stage_rank(dispatch.state),
      },
      caller_from_states = json_array({ "implementing" }),
      incoming_version = dispatch.version,
      target_version = nullable(replay_version),
      handoff_reference = JSON_NULL,
    },
    old_outcome = {
      status = fixture.expected_status,
      reason_code = fixture.expected_reason,
      cas_outcome = dispatch.decisions[1].outcome,
      emitted_effects = emitted_effects,
      observable_writes = observable_writes,
      handoff_direct_lookup_count = captured.handoff_direct_lookup_count,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      { kind = "runtime-row-replay-dispatch", ref = "packages/github-devloop/departments/observe_issue/main.lua:179-183" },
      { kind = "runtime-row-replay-handler", ref = "libraries/devloop/replayer.lua:118-154" },
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
    local value = tuple(fixture.name, fixture.expected_status, fixture.expected_reason, fixture.expected_target, fixture.expected_effect_ids)
    if tuples[value] ~= nil then error("duplicate production fixture tuple: " .. value, 0) end
    tuples[value] = true
  end
  return tuples
end

local function record_tuple_set(records, label)
  local tuples = {}
  for _, record in ipairs(records) do
    local observation_id = tostring(record.observation_id or "")
    if observation_id:sub(1, #OBSERVATION_PREFIX) ~= OBSERVATION_PREFIX then
      error(label .. " has unexpected observation_id " .. observation_id, 0)
    end
    local value = tuple(
      observation_id:sub(#OBSERVATION_PREFIX + 1),
      tostring(record.old_outcome.status or ""),
      tostring(record.old_outcome.reason_code or ""),
      tostring(record.typed_intent.target or ""),
      effect_id_list(record.old_outcome.emitted_effects)
    )
    if tuples[value] ~= nil then error(label .. " contains duplicate tuple: " .. value, 0) end
    tuples[value] = true
  end
  return tuples
end

local function assert_bidirectional(actual, expected, actual_label, expected_label, records)
  for value in pairs(actual) do
    if expected[value] == nil then error(actual_label .. " tuple absent from " .. expected_label .. ": " .. value .. "; records=" .. canonical_json(records), 0) end
  end
  for value in pairs(expected) do
    if actual[value] == nil then error(expected_label .. " tuple absent from " .. actual_label .. ": " .. value .. "; records=" .. canonical_json(records), 0) end
  end
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
    if type(site) == "table" and site.path == SITE.path and site.symbol == SITE.symbol and site.ordinal == SITE.ordinal then
      table.insert(selected, record)
    end
  end
  table.sort(selected, function(left, right) return left.observation_id < right.observation_id end)
  return selected
end

return {
  test_replayer_implementing_row_replay_old_behavior_is_real_dispatch_and_bidirectional = function()
    local fixtures = fixture_tuple_set()
    local first = capture_records()
    local second = capture_records()
    t.eq(#first, 4, "complete production-reachable implementing replay disposition count")
    local repeat_difference = first_difference(second, first, "old_behavior_observations[replayer-implementing][repeat]")
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then
      error("second OLD implementing row replay capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
    end
    local runtime_tuples = record_tuple_set(first, "runtime records")
    assert_bidirectional(runtime_tuples, fixtures, "runtime records", "production fixture lattice", first)
    local expected = committed_records()
    assert_bidirectional(runtime_tuples, record_tuple_set(expected, "inventory records"), "runtime records", "inventory records", first)
    local difference = first_difference(first, expected, "old_behavior_observations[replayer-implementing]")
    if difference ~= nil or canonical_json(first) ~= canonical_json(expected) then
      error("runtime-bound OLD implementing row replay observation differs at " .. tostring(difference or "canonical-json") .. "; runtime_records=" .. canonical_json(first), 0)
    end

    local drifted = copy_value(first)
    drifted[1].old_outcome.emitted_effects = {}
    local root = "old_behavior_observations[replayer-implementing][negative_control]"
    local drift = first_difference(drifted, first, root)
    t.is_true(canonical_json(drifted) ~= canonical_json(first), "empty array to object drift changes JSON")
    t.is_true(drift ~= nil and drift:find(root .. ".1.old_outcome.emitted_effects", 1, true) ~= nil, tostring(drift))
  end,
}
