local base_ids = require("devloop.base_ids")
local config = require("devloop.config")
local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local observation_support = require("testkit.old_behavior_observation_support")
local payloads_builders = require("devloop.payloads.builders")
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
local OBSERVATION_PREFIX = "row-replay:github-devloop:replayer-thinking/"
local SITE = {
  path = "libraries/devloop/replayer.lua",
  symbol = "replay_thinking",
  ordinal = "row-replay/thinking",
}

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = base_ids.proposal_id(REPO, ISSUE_NUMBER)
local UPDATED_AT = "2026-06-03T01:02:03Z"
local MARKER_CREATED_AT = "2099-01-01T00:00:00Z"
local SOURCE_REF = { kind = "external", ref = "owner/repo#issue/42" }

local function event_payload()
  return h.issue({
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture thinking row replay behavior",
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

local BASE_VERSION = payloads_builders.build_proposal(event_payload()).dedup_key
local CONVERGE_BASE_VERSION = "consensus:" .. BASE_VERSION

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T01:00:00Z",
  }
end

local function converge_round_comment(round, options)
  local selected = options or {}
  local dedup = round == 0 and CONVERGE_BASE_VERSION
    or transition_version.loop_at(CONVERGE_BASE_VERSION, round)
  return trusted_comment(conv_rounds.converge_round_marker(
    PROPOSAL_ID,
    CONVERGE_BASE_VERSION,
    convergence_shared.source_ref_digest(SOURCE_REF),
    round,
    dedup,
    selected.question or ("Narrowed question " .. tostring(round)),
    {
      {
        angle = "minimal",
        verdict = selected.verdict or "abstain",
        digest = "thinking-row-replay-digest-" .. tostring(round),
      },
    },
    selected.findings_record,
    selected.essence_stall == true
  ), "2026-06-03T01:01:00Z")
end

local function comments_for(fixture)
  local comments = json_array({
    trusted_comment(
      core.state_marker(PROPOSAL_ID, "thinking", BASE_VERSION),
      MARKER_CREATED_AT
    ),
  })
  if fixture.converge_round ~= nil then
    table.insert(comments, converge_round_comment(fixture.converge_round, fixture))
  end
  return comments
end

local EFFECTS = {
  ["consensus.proposal"] = {
    effect_id = "queue:consensus.proposal",
    sink_kind = "queue",
    authority_class = "lifecycle-authoritative",
  },
  ["github-proxy.github_issue_comment_request"] = {
    effect_id = "comment:issue:reconcile-blocked",
    sink_kind = "comment",
    authority_class = "lifecycle-authoritative",
  },
  ["github-proxy.github_issue_label_request"] = {
    effect_id = "label:issue:reconcile-blocked",
    sink_kind = "label",
    authority_class = "lifecycle-authoritative",
  },
}

local FIXTURES = json_array({
  {
    name = "plain-proposal-reraise",
    expected_status = "re-raised",
    expected_reason = "replay-current-thinking-proposal",
    expected_decision = "applied(replay)",
    expected_target = "consensus.proposal",
    expected_effect_ids = json_array({ "queue:consensus.proposal" }),
    expected_issued = true,
    expected_department_raises = 1,
  },
  {
    name = "next-converge-round-reraise",
    converge_round = 0,
    question = "Latest visible question",
    expected_status = "re-raised",
    expected_reason = "replay-next-converge-round-proposal",
    expected_decision = "applied(replay)",
    expected_target = "consensus.proposal",
    expected_effect_ids = json_array({ "queue:consensus.proposal" }),
    expected_issued = true,
    expected_department_raises = 1,
  },
  {
    name = "matching-live-run-defer",
    live_run = true,
    expected_status = "no-op",
    expected_reason = "matching-consensus-run-live",
    expected_decision = "skip-idempotent(live-exec-ref)",
    expected_target = "consensus.proposal",
    expected_effect_ids = json_array(),
    expected_issued = false,
    expected_department_raises = 3,
  },
  {
    name = "terminal-convergence-route-blocked",
    converge_round = 1,
    expected_status = "route-to-transition",
    expected_reason = "evidence-continuation-budget-exhausted-after-1-rounds",
    expected_decision = "applied",
    expected_target = "blocked",
    expected_effect_ids = json_array({
      "comment:issue:reconcile-blocked",
      "label:issue:reconcile-blocked",
    }),
    expected_issued = true,
    expected_department_raises = 2,
  },
})

local function controlled_codex_runs(fixture)
  if fixture.live_run ~= true then
    return json_array()
  end
  return json_array({
    {
      role = "consensus",
      proposal_id = PROPOSAL_ID,
      dedup_key = BASE_VERSION,
      status = "running",
    },
  })
end

local function prepare_fixture(fixture)
  h.mock_bot_env()
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture thinking row replay behavior",
    body = "",
    updated_at = UPDATED_AT,
    state = "OPEN",
    labels = { "fkst-dev:enabled", "fkst-dev:thinking" },
    comments = comments_for(fixture),
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    created_at = "2026-06-01T00:00:00Z",
    times = 1,
  })
  h.mock_context_bundle(event_payload())
end

local function effect_observations(raises)
  local emitted = json_array()
  local writes = json_array()
  for ordinal, raised in ipairs(raises) do
    local shape = EFFECTS[raised.queue]
    if shape == nil then
      error("unclassified thinking row replay OLD raise: " .. tostring(raised.queue), 0)
    end
    table.insert(emitted, {
      effect_id = shape.effect_id,
      sink_kind = shape.sink_kind,
      authority_class = shape.authority_class,
      ordinal = ordinal,
    })
    table.insert(writes, {
      effect_id = shape.effect_id,
      queue = raised.queue,
      payload = copy_value(raised.payload),
    })
  end
  return emitted, writes
end

local function effect_id_list(effects)
  local ids = json_array()
  for _, effect in ipairs(effects or {}) do
    table.insert(ids, tostring(effect.effect_id))
  end
  return ids
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
      raises = json_array(),
      applies = json_array(),
    }
    local active_log_raise = devloop_logging.log_raise
    local active_log_apply = devloop_logging.log_apply
    devloop_logging.log_raise = function(log_dept, proposal_id, queue, payload)
      table.insert(dispatch.raises, {
        proposal_id = proposal_id,
        queue = queue,
        payload = copy_value(payload),
      })
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
    if not replay_ok then
      error(issued, 0)
    end
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
      from_state = "thinking",
      transition_kind = "versioned_transition_status",
      run = function()
        return testing.run_fake(observe_issue_department, event)
      end,
      codex_runs_for_read = controlled_codex_runs(fixture),
      write_mode = "real",
    })
  end)
  replayer.replay_from_table = original_replay_from_table
  if not ok then
    error(result, 0)
  end

  t.eq(#dispatch_calls, 1, fixture.name .. ": real observe_issue dispatch reaches replay_from_table once")
  local dispatch = dispatch_calls[1]
  t.eq(dispatch.dept, "observe_issue", fixture.name .. ": production replay department")
  t.eq(dispatch.state, "thinking", fixture.name .. ": production-derived replay state")
  t.eq(dispatch.version, BASE_VERSION, fixture.name .. ": production-derived replay version")
  t.eq(dispatch.row_from_state, "thinking", fixture.name .. ": production thinking row")
  t.eq(dispatch.driving_queue, "consensus.proposal", fixture.name .. ": production thinking driving queue")
  t.eq(dispatch.issued, fixture.expected_issued, fixture.name .. ": exact row replay return disposition")
  t.eq(#captured.decisions, 1, fixture.name .. ": one replay disposition")
  t.eq(captured.decisions[1].outcome, fixture.expected_decision, fixture.name .. ": exact replay decision")
  t.eq(captured.decisions[1].to_state, fixture.expected_target, fixture.name .. ": exact replay target")
  t.eq(#result.raises, fixture.expected_department_raises, fixture.name .. ": complete real department effects")
  t.eq(#dispatch.raises, #fixture.expected_effect_ids, fixture.name .. ": row-local effect count")
  for index, raised in ipairs(dispatch.raises) do
    t.eq(captured.raises[index].queue, raised.queue, fixture.name .. ": row-local logged raise queue " .. tostring(index))
    t.eq(
      canonical_json(captured.raises[index].payload),
      canonical_json(raised.payload),
      fixture.name .. ": row-local logged raise payload " .. tostring(index)
    )
  end
  return event, result, captured, dispatch
end

local function build_record(fixture)
  local event, _, captured, dispatch = capture_runtime(fixture)
  local emitted_effects, observable_writes = effect_observations(dispatch.raises)
  t.eq(
    canonical_json(effect_id_list(emitted_effects)),
    canonical_json(fixture.expected_effect_ids),
    fixture.name .. ": exact effect disposition"
  )

  local target_version = nil
  if fixture.expected_target == "consensus.proposal" and dispatch.raises[1] ~= nil then
    target_version = dispatch.raises[1].payload.dedup_key
  elseif fixture.expected_target == "blocked" then
    target_version = dispatch.applies[1] and dispatch.applies[1].version or nil
  end
  local converge_round = fixture.converge_round
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_PREFIX .. fixture.name,
    owner = "github-devloop",
    site = copy_value(SITE),
    boundary = "row_replay",
    typed_intent = {
      kind = "row_replay",
      source_state = "thinking",
      source_boundary = event.queue,
      target = fixture.expected_target,
      cause_schema_id = event.payload.schema,
      generation_epoch = {
        state_version = dispatch.version,
        replay_version = nullable(target_version),
        converge_round = nullable(converge_round),
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
      caller_from_states = json_array({ "thinking" }),
      incoming_version = dispatch.version,
      target_version = nullable(target_version),
      handoff_reference = JSON_NULL,
    },
    old_outcome = {
      status = fixture.expected_status,
      reason_code = fixture.expected_reason,
      cas_outcome = captured.decisions[1].outcome,
      emitted_effects = emitted_effects,
      observable_writes = observable_writes,
      handoff_direct_lookup_count = captured.handoff_direct_lookup_count,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      {
        kind = "runtime-row-replay-dispatch",
        ref = "packages/github-devloop/departments/observe_issue/main.lua:179-183",
      },
      {
        kind = "runtime-row-replay-handler",
        ref = "libraries/devloop/replayer.lua:111-115",
      },
      {
        kind = "runtime-disposition",
        ref = "devloop.logging.log_cas_decision:observe_issue:" .. captured.decisions[1].outcome,
      },
      {
        kind = "runtime-event-source",
        ref = event.payload.source_ref.ref,
      },
    }),
  }
end

local function fixture_tuple(fixture)
  return table.concat({
    fixture.name,
    fixture.expected_status,
    fixture.expected_reason,
    fixture.expected_target,
    table.concat(fixture.expected_effect_ids, ","),
  }, "|")
end

local function record_tuple(record, label)
  local observation_id = tostring(record.observation_id or "")
  if observation_id:sub(1, #OBSERVATION_PREFIX) ~= OBSERVATION_PREFIX then
    error(label .. " has unexpected observation_id " .. observation_id, 0)
  end
  local variant = observation_id:sub(#OBSERVATION_PREFIX + 1)
  if variant == "" then
    error(label .. " has an empty row replay variant", 0)
  end
  return table.concat({
    variant,
    tostring(record.old_outcome and record.old_outcome.status or ""),
    tostring(record.old_outcome and record.old_outcome.reason_code or ""),
    tostring(record.typed_intent and record.typed_intent.target or ""),
    table.concat(effect_id_list(record.old_outcome and record.old_outcome.emitted_effects), ","),
  }, "|")
end

local function fixture_tuple_set()
  local tuples = {}
  for _, fixture in ipairs(FIXTURES) do
    local tuple = fixture_tuple(fixture)
    if tuples[tuple] ~= nil then
      error("duplicate production fixture tuple: " .. tuple, 0)
    end
    tuples[tuple] = true
  end
  return tuples
end

local function record_tuple_set(records, label)
  local tuples = {}
  for index, record in ipairs(records) do
    local tuple = record_tuple(record, label .. "[" .. tostring(index) .. "]")
    if tuples[tuple] ~= nil then
      error(label .. " contains duplicate tuple: " .. tuple, 0)
    end
    tuples[tuple] = true
  end
  return tuples
end

local function assert_bidirectional_membership(actual, expected, actual_label, expected_label, actual_records)
  local detail = actual_records and "; actual_records=" .. canonical_json(actual_records) or ""
  for tuple in pairs(actual) do
    if expected[tuple] == nil then
      error(actual_label .. " tuple is absent from " .. expected_label .. ": " .. tuple .. detail, 0)
    end
  end
  for tuple in pairs(expected) do
    if actual[tuple] == nil then
      error(expected_label .. " tuple is absent from " .. actual_label .. ": " .. tuple .. detail, 0)
    end
  end
end

local function capture_records()
  local records = json_array()
  for _, fixture in ipairs(FIXTURES) do
    table.insert(records, build_record(fixture))
  end
  table.sort(records, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  return records
end

local function is_target_record(record)
  local site = type(record) == "table" and record.site or nil
  return type(site) == "table"
    and site.path == SITE.path
    and site.symbol == SITE.symbol
    and site.ordinal == SITE.ordinal
end

local function committed_records()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  local selected = json_array()
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if is_target_record(record) then
      table.insert(selected, record)
    end
  end
  table.sort(selected, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  return selected
end

local function assert_internal_no_op_branches_are_not_production_reachable()
  local terminal_fixture = FIXTURES[4]
  local terminal_comments = comments_for(terminal_fixture)
  local reconcile = {
    proposal_id = PROPOSAL_ID,
    base_version = BASE_VERSION,
    round = 1,
    terminal_cause = "evidence-continuation-budget-exhausted",
    dedup_key = "reconcile:" .. transition_version.loop_at(BASE_VERSION, 1),
    source_ref = copy_value(SOURCE_REF),
  }
  local terminal_version = transition_version.loop_at(BASE_VERSION, 1)
  local request = core.build_reconcile_comment_request(
    REPO,
    ISSUE_NUMBER,
    reconcile,
    "drop",
    terminal_fixture.expected_reason,
    terminal_version
  )
  table.insert(terminal_comments, trusted_comment(request.body, "2026-06-03T01:02:00Z"))
  local derived = devloop_state.current_state(terminal_comments, PROPOSAL_ID)
  t.eq(derived.state, "blocked", "visible reconcile marker is production-paired with blocked state marker")
  t.eq(derived.version, terminal_version, "paired blocked marker carries the terminal replay version")
  t.eq(
    devloop_state.versioned_transition_status(
      { state = "thinking", version = BASE_VERSION },
      { "thinking" },
      "blocked",
      terminal_version
    ),
    "apply",
    "production thinking-to-blocked replay CAS cannot be idempotent or stale"
  )
end

return {
  test_replayer_thinking_row_replay_old_behavior_is_real_dispatch_and_bidirectional = function()
    assert_internal_no_op_branches_are_not_production_reachable()
    local fixtures = fixture_tuple_set()
    local first = capture_records()
    local second = capture_records()
    t.eq(#first, 4, "complete production-reachable thinking row replay observation count")
    local repeat_difference = first_difference(
      second,
      first,
      "old_behavior_observations[replayer-thinking-row-replay][repeat]"
    )
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then
      error("second OLD thinking row replay runtime capture differs at "
        .. tostring(repeat_difference or "canonical-json"), 0)
    end

    local runtime_tuples = record_tuple_set(first, "runtime records")
    assert_bidirectional_membership(runtime_tuples, fixtures, "runtime records", "production fixture lattice", first)
    local expected = committed_records()
    local inventory_tuples = record_tuple_set(expected, "inventory records")
    assert_bidirectional_membership(runtime_tuples, inventory_tuples, "runtime records", "inventory records", first)
    local inventory_difference = first_difference(
      first,
      expected,
      "old_behavior_observations[replayer-thinking-row-replay]"
    )
    if inventory_difference ~= nil or canonical_json(first) ~= canonical_json(expected) then
      error(
        "runtime-bound OLD thinking row replay observation differs at "
          .. tostring(inventory_difference or "canonical-json")
          .. "; runtime_records=" .. canonical_json(first),
        0
      )
    end
  end,
}
