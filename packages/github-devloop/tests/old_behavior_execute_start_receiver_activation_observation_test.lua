local config = require("devloop.config")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local execution_start = require("devloop.execution_start")
local h = require("tests.devloop_helpers")
local observation_support = require("testkit.old_behavior_observation_support")
local testing = require("testkit.testing")
local execute_start_department = require("departments.execute_start.main")

local t = h.t
local JSON_NULL = observation_support.JSON_NULL
local JSON_ARRAY_TAG = observation_support.JSON_ARRAY_TAG
local JSON_OBJECT_TAG = observation_support.JSON_OBJECT_TAG
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local nullable = observation_support.nullable
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local OBSERVATION_PREFIX = "receiver-activation-execute-start-"
local SITE = {
  path = "packages/github-devloop/departments/execute_start/main.lua",
  symbol = "pipeline",
  ordinal = "consumes:github-devloop.devloop_execute_request",
}

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local REQUEST_VERSION = "intake/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local SOURCE_REF = { kind = "external", ref = "owner/repo#issue/42" }
local EVENT_QUEUE = "github-devloop.devloop_execute_request"

local EFFECTS = {
  ["github-proxy.github_issue_comment_request"] = {
    effect_id = "comment:issue:thinking-state",
    sink_kind = "comment",
    authority_class = "lifecycle-authoritative",
  },
  ["github-proxy.github_issue_label_request"] = {
    effect_id = "label:issue:thinking-state",
    sink_kind = "label",
    authority_class = "lifecycle-authoritative",
  },
  ["consensus.proposal"] = {
    effect_id = "queue:consensus.proposal",
    sink_kind = "queue",
    authority_class = "lifecycle-authoritative",
  },
}

local function execution_request(extra)
  local payload = execution_start.build_execution_request_payload({
    proposal_id = PROPOSAL_ID,
    dedup_key = REQUEST_VERSION,
    source_ref = copy_value(SOURCE_REF),
    origin = {
      package = "github-devloop-intake-default",
      route = "default",
      decision = "enable",
    },
    service_class = "expedite",
  })
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return payload
end

local function current_issue(extra)
  local issue = {
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture execute-start receiver activation",
    body = "Observe the production receiver admission boundary.",
    created_at = "2026-06-03T01:00:00Z",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = {},
    comments = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }
  for key, value in pairs(extra or {}) do
    issue[key] = value
  end
  return issue
end

local FIXTURES = json_array({
  {
    disposition = "skip-foreign-payload",
    request = {
      schema = "unsupported.execution-request.v1",
      proposal_id = PROPOSAL_ID,
      dedup_key = REQUEST_VERSION,
      source_ref = copy_value(SOURCE_REF),
    },
    expected_status = "rejected",
    expected_reason = "skip-foreign(payload)",
    expected_cas = "skip-foreign(payload)",
    expected_target = "reject",
    decision_from_state = "execution-request",
    source_line = 76,
  },
  {
    disposition = "skip-closed",
    issue = current_issue({ state = "CLOSED" }),
    expected_status = "rejected",
    expected_reason = "skip-closed",
    expected_cas = "skip-closed",
    expected_target = "reject",
    decision_from_state = "execution-request",
    source_line = 37,
  },
  {
    disposition = "skip-held",
    issue = current_issue({ labels = { "fkst-dev:hold" } }),
    expected_status = "rejected",
    expected_reason = "skip-held",
    expected_cas = "skip-held",
    expected_target = "reject",
    decision_from_state = "execution-request",
    source_line = 41,
  },
  {
    disposition = "claim-not-acquired",
    issue = current_issue({ assignees = { "other-login" } }),
    expected_status = "rejected",
    expected_reason = "claim-not-acquired",
    expected_cas = "skip-claimed-by-other",
    expected_target = "reject",
    decision_from_state = "claim",
    source_line = 44,
  },
  {
    disposition = "cannot-build-effects",
    issue = current_issue({ title = "" }),
    needs_context = true,
    expected_status = "rejected",
    expected_reason = "cannot-build-effects",
    expected_cas = "not-applicable-build-rejected",
    expected_target = "reject",
    expected_builder_calls = 1,
    source_line = 52,
  },
  {
    disposition = "activate-thinking",
    issue = current_issue(),
    needs_context = true,
    expected_status = "activated",
    expected_reason = "activate-thinking",
    expected_cas = "applied(receiver-activation)",
    expected_target = "thinking",
    expected_builder_calls = 1,
    expected_effect_ids = json_array({
      "comment:issue:thinking-state",
      "label:issue:thinking-state",
      "queue:consensus.proposal",
    }),
    source_line = 58,
  },
})

local function event_for(request)
  return {
    queue = EVENT_QUEUE,
    ts = "2026-06-03T01:02:04Z",
    payload = request,
  }
end

local function prepare_fixture(fixture, request)
  h.mock_bot_env()
  if fixture.issue ~= nil then
    entity_read_mocks.mock_issue_view_selector(
      t,
      fixture.issue,
      "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone",
      1
    )
  end
  if fixture.needs_context == true then
    h.mock_context_bundle(request)
  end
end

local function effect_observations(raises)
  local emitted = json_array()
  local writes = json_array()
  for ordinal, raised in ipairs(raises or {}) do
    local shape = EFFECTS[raised.queue]
    if shape == nil then
      error("unclassified execute_start receiver activation OLD raise: " .. tostring(raised.queue), 0)
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
  local request = fixture.request and copy_value(fixture.request) or execution_request()
  local event = event_for(request)
  prepare_fixture(fixture, request)
  local builder_calls = json_array()
  local original_builder = execution_start.build_execution_start_effects
  execution_start.build_execution_start_effects = function(core, repo, issue_number, source, current, event_ts, dept)
    local effects = original_builder(core, repo, issue_number, source, current, event_ts, dept)
    table.insert(builder_calls, {
      current = copy_value(current),
      effects = copy_value(effects),
    })
    return effects
  end

  local ok, result, captured = pcall(function()
    return observation_support.observe_department({
      config = config,
      devloop_logging = devloop_logging,
      devloop_state = devloop_state,
      dept = "execute_start",
      from_state = fixture.decision_from_state or "receiver-activation-no-cas",
      write_mode = "real",
      run = function()
        return testing.run_fake(execute_start_department, event)
      end,
    })
  end)
  execution_start.build_execution_start_effects = original_builder
  if not ok then
    error(result, 0)
  end

  t.eq(#builder_calls, fixture.expected_builder_calls or 0, fixture.disposition .. ": exact builder call count")
  t.eq(#captured.raises, #result.raises, fixture.disposition .. ": logger and real department raise counts")
  t.eq(#captured.applies, fixture.expected_target == "thinking" and 1 or 0, fixture.disposition .. ": apply count")
  if fixture.decision_from_state ~= nil then
    t.eq(#captured.decisions, 1, fixture.disposition .. ": exact admission decision count")
    t.eq(captured.decisions[1].outcome, fixture.expected_cas, fixture.disposition .. ": exact admission decision")
  else
    t.eq(#captured.decisions, 0, fixture.disposition .. ": no manufactured CAS decision")
  end
  if fixture.disposition == "cannot-build-effects" then
    t.eq(builder_calls[1].effects, nil, "real builder rejects the empty-title issue projection")
  elseif fixture.disposition == "activate-thinking" then
    t.is_true(builder_calls[1].effects ~= nil, "real builder returns the complete activation effects")
    t.eq(captured.applies[1].to_state, "thinking", "activation applies thinking")
  end
  return event, result, captured, builder_calls[1]
end

local function build_record(fixture)
  local event, result, captured, builder_call = capture_runtime(fixture)
  local emitted_effects, observable_writes = effect_observations(result.raises)
  local expected_effect_ids = fixture.expected_effect_ids or json_array()
  t.eq(
    canonical_json(effect_id_list(emitted_effects)),
    canonical_json(expected_effect_ids),
    fixture.disposition .. ": exact receiver activation effect disposition"
  )

  local current = builder_call and builder_call.current or fixture.issue
  local request = event.payload
  local handoff = nil
  if fixture.disposition == "activate-thinking" then
    handoff = execution_start.execution_intake_hand_off(request)
  end
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_PREFIX .. fixture.disposition,
    owner = "github-devloop",
    site = copy_value(SITE),
    boundary = "receiver_activation",
    typed_intent = {
      kind = "receiver_activation",
      source_state = "execution-request",
      source_boundary = event.queue,
      target = fixture.expected_target,
      cause_schema_id = tostring(request.schema or "missing-schema"),
      generation_epoch = {
        current_version = JSON_NULL,
        request_version = nullable(request.dedup_key),
        effect_version = fixture.expected_target == "thinking" and request.dedup_key or JSON_NULL,
      },
      lineage = {
        proposal_id = nullable(request.proposal_id),
        issue_number = current and ISSUE_NUMBER or JSON_NULL,
        source_ref = nullable(copy_value(request.source_ref)),
      },
    },
    old_inputs = {
      current_fact = {
        issue_state = nullable(current and current.state),
        labels = current and json_array(current.labels) or json_array(),
        assignees = current and json_array(current.assignees) or json_array(),
      },
      caller_from_states = json_array({ "execution-request" }),
      incoming_version = nullable(request.dedup_key),
      target_version = fixture.expected_target == "thinking" and request.dedup_key or JSON_NULL,
      handoff_reference = nullable(copy_value(handoff)),
    },
    old_outcome = {
      status = fixture.expected_status,
      reason_code = fixture.expected_reason,
      cas_outcome = fixture.expected_cas,
      emitted_effects = emitted_effects,
      observable_writes = observable_writes,
      handoff_direct_lookup_count = captured.handoff_direct_lookup_count,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      {
        kind = "runtime-receiver-activation",
        ref = "packages/github-devloop/departments/execute_start/main.lua:" .. tostring(fixture.source_line),
      },
      {
        kind = "runtime-event-source",
        ref = event.queue,
      },
    }),
  }
end

local function fixture_tuple(fixture)
  return table.concat({
    fixture.disposition,
    fixture.expected_status,
    fixture.expected_reason,
    fixture.expected_cas,
    fixture.expected_target,
    table.concat(fixture.expected_effect_ids or {}, ","),
  }, "|")
end

local function record_tuple(record, label)
  local observation_id = tostring(record.observation_id or "")
  if observation_id:sub(1, #OBSERVATION_PREFIX) ~= OBSERVATION_PREFIX then
    error(label .. " has unexpected observation_id " .. observation_id, 0)
  end
  return table.concat({
    observation_id:sub(#OBSERVATION_PREFIX + 1),
    tostring(record.old_outcome and record.old_outcome.status or ""),
    tostring(record.old_outcome and record.old_outcome.reason_code or ""),
    tostring(record.old_outcome and record.old_outcome.cas_outcome or ""),
    tostring(record.typed_intent and record.typed_intent.target or ""),
    table.concat(effect_id_list(record.old_outcome and record.old_outcome.emitted_effects), ","),
  }, "|")
end

local function tuple_set(records, tuple, label)
  local tuples = {}
  for index, record in ipairs(records) do
    local value = tuple(record, label .. "[" .. tostring(index) .. "]")
    if tuples[value] ~= nil then
      error(label .. " contains duplicate tuple: " .. value, 0)
    end
    tuples[value] = true
  end
  return tuples
end

local function assert_bidirectional_membership(actual, expected, actual_label, expected_label, actual_records)
  local detail = actual_records and "; actual_records=" .. canonical_json(actual_records) or ""
  for value in pairs(actual) do
    if expected[value] == nil then
      error(actual_label .. " tuple is absent from " .. expected_label .. ": " .. value .. detail, 0)
    end
  end
  for value in pairs(expected) do
    if actual[value] == nil then
      error(expected_label .. " tuple is absent from " .. actual_label .. ": " .. value .. detail, 0)
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

local function assert_source_ref_branch_is_not_production_reachable()
  local request = execution_request({
    source_ref = { kind = "external", ref = "not-an-issue-ref" },
  })
  local event = event_for(request)
  local _, captured = observation_support.observe_department({
    config = config,
    devloop_logging = devloop_logging,
    devloop_state = devloop_state,
    dept = "execute_start",
    from_state = "execution-request",
    write_mode = "real",
    run = function()
      return testing.run_fake(execute_start_department, event)
    end,
  })
  t.eq(#captured.decisions, 1, "invalid source_ref is rejected by the request validator")
  t.eq(captured.decisions[1].outcome, "skip-foreign(payload)")
  for _, line in ipairs(captured.lines) do
    local fields = table.concat(line.fields or {}, " ")
    t.is_true(fields:find("skip-foreign(source_ref)", 1, true) == nil)
  end
end

return {
  test_execute_start_receiver_activation_empty_array_object_negative_control = function()
    t.is_true(JSON_ARRAY_TAG ~= JSON_OBJECT_TAG, "json.decode preserves array versus object shape")
    local expected = { emitted_effects = json_array() }
    local drifted = copy_value(expected)
    drifted.emitted_effects = {}
    local root = "old_behavior_observations[execute-start-receiver-activation][negative_control]"
    local difference = first_difference(drifted, expected, root)
    t.eq(canonical_json(expected.emitted_effects), "[]", "empty effects retain array shape")
    t.is_true(canonical_json(drifted) ~= canonical_json(expected), "empty array to object drift changes JSON")
    t.is_true(difference ~= nil and difference:find(root .. ".emitted_effects", 1, true) ~= nil)
  end,

  test_execute_start_receiver_activation_old_behavior_is_real_dispatch_and_bidirectional = function()
    assert_source_ref_branch_is_not_production_reachable()
    local fixture_tuples = tuple_set(FIXTURES, function(fixture) return fixture_tuple(fixture) end, "fixture lattice")
    local first = capture_records()
    local second = capture_records()
    t.eq(#first, 6, "complete production receiver activation disposition count")
    local repeat_difference = first_difference(
      second,
      first,
      "old_behavior_observations[execute-start-receiver-activation][repeat]"
    )
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then
      error("second OLD execute_start receiver activation capture differs at "
        .. tostring(repeat_difference or "canonical-json"), 0)
    end

    local runtime_tuples = tuple_set(first, record_tuple, "runtime records")
    assert_bidirectional_membership(runtime_tuples, fixture_tuples, "runtime records", "production fixture lattice", first)
    local expected = committed_records()
    local inventory_tuples = tuple_set(expected, record_tuple, "inventory records")
    assert_bidirectional_membership(runtime_tuples, inventory_tuples, "runtime records", "inventory records", first)
    local inventory_difference = first_difference(
      first,
      expected,
      "old_behavior_observations[execute-start-receiver-activation]"
    )
    if inventory_difference ~= nil or canonical_json(first) ~= canonical_json(expected) then
      error(
        "runtime-bound OLD execute_start receiver activation observation differs at "
          .. tostring(inventory_difference or "canonical-json")
          .. "; runtime_records=" .. canonical_json(first),
        0
      )
    end
  end,
}
