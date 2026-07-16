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
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local PROPOSAL_QUEUE = "consensus.proposal"
local OBSERVATION_PREFIX = "intent:github-devloop:execute-start/"
local SITE = {
  path = "packages/github-devloop/departments/execute_start/main.lua",
  symbol = "pipeline",
  ordinal = PROPOSAL_QUEUE,
}

local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local REQUEST_VERSION = "intake/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local SOURCE_REF = { kind = "external", ref = "owner/repo#issue/42" }
local VARIANTS = json_array({ "intake-enable" })

local function execution_request()
  return execution_start.build_execution_request_payload({
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
end

local function event_for(request)
  return {
    queue = "devloop_execute_request",
    ts = "2026-06-03T01:02:04Z",
    payload = request,
  }
end

local function prepare_fixture(request)
  h.mock_bot_env()
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = "owner/repo",
    number = 42,
    title = "Capture execute-start consensus proposal",
    body = "Record the production constructor payload.",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = {},
    comments = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author", 1)
  h.mock_context_bundle(request)
end

local function only_proposal_raise(raises, label)
  local selected = json_array()
  for _, raised in ipairs(raises) do
    if raised.queue == PROPOSAL_QUEUE then
      table.insert(selected, raised)
    end
  end
  t.eq(#selected, 1, label .. " contains exactly one consensus proposal")
  return selected[1]
end

local function capture_runtime()
  local request = execution_request()
  local event = event_for(request)
  prepare_fixture(request)
  local constructor_payloads = json_array()
  local original_builder = execution_start.build_execution_start_effects

  execution_start.build_execution_start_effects = function(core, repo, issue_number, source, current, event_ts, dept)
    local effects = original_builder(core, repo, issue_number, source, current, event_ts, dept)
    table.insert(constructor_payloads, copy_value(effects and effects.proposal))
    return effects
  end

  local ok, result, captured = pcall(function()
    local run_result, run_capture = observation_support.observe_department({
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
    return run_result, run_capture
  end)
  execution_start.build_execution_start_effects = original_builder
  if not ok then
    error(result, 0)
  end

  t.eq(#constructor_payloads, 1, "real execute_start dispatch calls the constructor exactly once")
  t.eq(#captured.raises, #result.raises, "raise spy and run_fake raise counts")
  local emitted = only_proposal_raise(result.raises, "run_fake emitted raises")
  local spied = only_proposal_raise(captured.raises, "raise-spy captures")
  t.eq(spied.queue, emitted.queue, "raise spy captures the emitted queue")
  t.eq(
    canonical_json(spied.payload),
    canonical_json(emitted.payload),
    "raise spy captures the complete emitted payload"
  )
  t.eq(
    canonical_json(spied.payload),
    canonical_json(constructor_payloads[1]),
    "published intent exactly matches the direct constructor variant"
  )
  t.eq(#captured.decisions, 0, "successful execute_start proposal raise has no competing CAS disposition")
  return event, copy_value(spied)
end

local function build_record()
  local event, raised = capture_runtime()
  local payload = raised.payload
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_PREFIX .. "intake-enable",
    owner = "github-devloop",
    site = copy_value(SITE),
    boundary = "published_intent_producer",
    typed_intent = {
      kind = "published_intent",
      source_state = "execution-request",
      source_boundary = event.queue,
      target = raised.queue,
      cause_schema_id = event.payload.schema,
      generation_epoch = {
        current_version = JSON_NULL,
        source_version = event.payload.dedup_key,
        payload_version = payload.dedup_key,
      },
      lineage = {
        proposal_id = payload.proposal_id,
        issue_number = 42,
        source_ref = copy_value(payload.source_ref),
        intake_hand_off = copy_value(payload.intake_hand_off),
      },
    },
    old_inputs = {
      current_fact = {
        state = JSON_NULL,
        version = JSON_NULL,
        stage_rank = JSON_NULL,
      },
      caller_from_states = json_array({ "execution-request" }),
      incoming_version = event.payload.dedup_key,
      target_version = payload.dedup_key,
      handoff_reference = copy_value(payload.intake_hand_off),
    },
    old_outcome = {
      status = "raised",
      reason_code = "intake-enable-proposal",
      cas_outcome = "not-applicable-published-intent",
      emitted_effects = json_array({
        {
          effect_id = "queue:consensus.proposal",
          sink_kind = "queue",
          authority_class = "lifecycle-authoritative",
          ordinal = 1,
        },
      }),
      observable_writes = json_array({
        {
          effect_id = "queue:consensus.proposal",
          queue = raised.queue,
          payload = copy_value(payload),
        },
      }),
      handoff_direct_lookup_count = 0,
      timeout_evidence_source = JSON_NULL,
    },
    evidence_refs = json_array({
      {
        kind = "runtime-raise-capture",
        ref = "devloop.logging.log_raise:execute_start:consensus.proposal",
      },
      {
        kind = "runtime-event-source",
        ref = event.payload.source_ref.ref,
      },
      {
        kind = "production-callsite",
        ref = "packages/github-devloop/departments/execute_start/main.lua:68",
      },
      {
        kind = "production-condition",
        ref = "libraries/devloop/execution_start.lua:60-80",
      },
    }),
  }
end

local function fixture_tuple_set()
  local tuples = {}
  for _, variant in ipairs(VARIANTS) do
    if tuples[variant] ~= nil then
      error("duplicate fixture tuple: " .. variant, 0)
    end
    tuples[variant] = true
  end
  return tuples
end

local function record_tuple_set(records, label)
  local tuples = {}
  for index, record in ipairs(records) do
    local observation_id = tostring(record.observation_id or "")
    if observation_id:sub(1, #OBSERVATION_PREFIX) ~= OBSERVATION_PREFIX then
      error(label .. "[" .. tostring(index) .. "] has unexpected observation_id " .. observation_id, 0)
    end
    local variant = observation_id:sub(#OBSERVATION_PREFIX + 1)
    if variant == "" then
      error(label .. "[" .. tostring(index) .. "] has an empty variant tuple", 0)
    end
    if tuples[variant] ~= nil then
      error(label .. " contains duplicate tuple " .. variant, 0)
    end
    tuples[variant] = true
  end
  return tuples
end

local function assert_bidirectional_tuple_membership(actual, expected, actual_label, expected_label, actual_records)
  local record_detail = actual_records and "; actual_records=" .. canonical_json(actual_records) or ""
  for key in pairs(actual) do
    if expected[key] == nil then
      error(actual_label .. " tuple is absent from " .. expected_label .. ": " .. key .. record_detail, 0)
    end
  end
  for key in pairs(expected) do
    if actual[key] == nil then
      error(expected_label .. " tuple is absent from " .. actual_label .. ": " .. key .. record_detail, 0)
    end
  end
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

return {
  test_execute_start_consensus_proposal_published_intent_is_real_dispatch_and_bidirectional = function()
    local fixture_tuples = fixture_tuple_set()
    local first = json_array({ build_record() })
    local second = json_array({ build_record() })
    local repeat_difference = first_difference(
      second,
      first,
      "old_behavior_observations[execute-start-consensus-proposal-intent][repeat]"
    )
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then
      error("second OLD published-intent runtime capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
    end

    local runtime_tuples = record_tuple_set(first, "runtime records")
    assert_bidirectional_tuple_membership(runtime_tuples, fixture_tuples, "runtime records", "production fixture lattice", first)
    local expected = committed_records()
    local inventory_tuples = record_tuple_set(expected, "inventory records")
    assert_bidirectional_tuple_membership(runtime_tuples, inventory_tuples, "runtime records", "inventory records", first)
    local inventory_difference = first_difference(
      first,
      expected,
      "old_behavior_observations[execute-start-consensus-proposal-intent]"
    )
    if inventory_difference ~= nil or canonical_json(first) ~= canonical_json(expected) then
      error(
        "runtime-bound OLD published-intent observation differs at "
          .. tostring(inventory_difference or "canonical-json")
          .. "; runtime_records=" .. canonical_json(first),
        0
      )
    end
  end,
}
