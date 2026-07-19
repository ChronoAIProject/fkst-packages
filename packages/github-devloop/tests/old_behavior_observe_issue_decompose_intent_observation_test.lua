local base_ids = require("devloop.base_ids")
local config = require("devloop.config")
local decompose_lib = require("devloop.decompose")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local testing = require("testkit_internal.testing")
local observe_issue_department = require("departments.observe_issue.main")

local t = h.t
local core = h.core
local JSON_NULL = observation_support.JSON_NULL
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local DECOMPOSE_QUEUE = "github-devloop-decompose.devloop_decompose"
local OBSERVATION_ID = "intent:github-devloop:observe-issue-decompose/republish"
local SITE = {
  path = "packages/github-devloop/departments/observe_issue/main.lua",
  symbol = "process_issue_event",
  ordinal = DECOMPOSE_QUEUE,
}

local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local BRANCH = "devloop-owner-repo-42-01HY"
local BASE_BRANCH = "dev"
local PROPOSAL_ID = base_ids.proposal_id(REPO, ISSUE_NUMBER)
local VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"
local SOURCE_REF = { kind = "external", ref = "owner/repo#issue/42" }

local function event_payload()
  return h.issue({
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture observe issue decompose replay",
    body = "",
    state = "OPEN",
    updated_at = "2026-06-03T01:02:03Z",
    dedup_key = "owner/repo#issue#42@2026-06-03T01:02:03Z",
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

local function prepare_fixture()
  h.mock_bot_env()
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = REPO,
    number = ISSUE_NUMBER,
    title = "Capture observe issue decompose replay",
    body = "",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = { "fkst-dev:enabled", "fkst-dev:blocked" },
    comments = {
      core.state_marker(PROPOSAL_ID, "blocked", VERSION),
      m_builders.pr_link_marker(PROPOSAL_ID, PR_NUMBER, BRANCH, VERSION, BASE_BRANCH),
      core.build_fix_reconcile_comment_request(REPO, tostring(ISSUE_NUMBER), {
        proposal_id = PROPOSAL_ID,
        issue_version = VERSION,
        dedup_key = "fix-reconcile:" .. VERSION,
        source_ref = { kind = "external", ref = "owner/repo#pr/7" },
      }, "drop", "fix-loop-max-rounds-after-3-rounds").body,
      decompose_lib.decomposed_marker(PROPOSAL_ID, VERSION, PR_NUMBER, 1),
    },
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    times = 1,
  })
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = REPO,
    number = PR_NUMBER,
    comments = {
      m_builders.pr_origin_marker(PROPOSAL_ID, ISSUE_NUMBER, BRANCH, VERSION, BASE_BRANCH),
    },
    head = BRANCH,
    head_sha = "def456",
    state = "OPEN",
    base_branch = BASE_BRANCH,
    labels = { "fkst-dev:blocked" },
  }, entity_read_mocks.pr_origin_selector, 1)
  t.mock_command(core.gh_issue_list_decompose_children_cmd(REPO, PROPOSAL_ID), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function only_decompose_raise(raises, label)
  local selected = json_array()
  for _, raised in ipairs(raises or {}) do
    if raised.queue == DECOMPOSE_QUEUE then table.insert(selected, raised) end
  end
  t.eq(#selected, 1, label .. " contains exactly one decompose intent")
  return selected[1]
end

local function capture_runtime()
  local event = issue_event()
  prepare_fixture()
  local constructor_payloads = json_array()
  local original_builder = decompose_lib.build_decompose_replay_payload

  decompose_lib.build_decompose_replay_payload = function(...)
    local payload = original_builder(...)
    table.insert(constructor_payloads, copy_value(payload))
    return payload
  end

  local ok, result, captured = pcall(function()
    local run_result, run_capture = observation_support.observe_department({
      config = config,
      devloop_logging = devloop_logging,
      devloop_state = devloop_state,
      dept = "observe_issue",
      from_state = "blocked",
      write_mode = "real",
      run = function()
        return testing.run_fake(observe_issue_department, event)
      end,
      codex_runs_for_read = json_array(),
    })
    return run_result, run_capture
  end)
  decompose_lib.build_decompose_replay_payload = original_builder
  if not ok then error(result, 0) end

  t.eq(
    #constructor_payloads,
    1,
    "real observe_issue dispatch calls the replay constructor once; decisions=" .. canonical_json(captured.decisions)
  )
  t.eq(#captured.raises, #result.raises, "raise spy and run_fake raise counts")
  local emitted = only_decompose_raise(result.raises, "run_fake emitted raises")
  local spied = only_decompose_raise(captured.raises, "raise-spy captures")
  t.eq(spied.queue, emitted.queue, "raise spy captures the emitted queue")
  t.eq(canonical_json(spied.payload), canonical_json(emitted.payload), "raise spy captures the complete emitted payload")
  t.eq(canonical_json(spied.payload), canonical_json(constructor_payloads[1]), "published intent exactly matches the direct constructor variant")
  t.eq(#captured.decisions, 1, "blocked replay records one routing decision")
  t.eq(captured.decisions[1].outcome, "applied(decomposed-children-missing)", "blocked replay reaches the decompose raise")
  return event, copy_value(spied), captured.decisions[1]
end

local function build_record()
  local event, raised, decision = capture_runtime()
  local payload = raised.payload
  t.eq(payload.expected_child_count, 1, "fixture preserves expected child count as payload data")
  t.eq(payload.completed_child_count, 0, "fixture preserves completed child count as payload data")
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_ID,
    owner = "github-devloop",
    site = copy_value(SITE),
    boundary = "published_intent_producer",
    typed_intent = {
      kind = "published_intent",
      source_state = "blocked",
      source_boundary = event.queue,
      target = raised.queue,
      cause_schema_id = event.payload.schema,
      generation_epoch = {
        current_version = VERSION,
        source_version = event.payload.dedup_key,
        payload_version = payload.dedup_key,
      },
      lineage = {
        proposal_id = payload.proposal_id,
        pr_number = payload.pr_number,
        source_ref = copy_value(payload.source_ref),
        expected_child_count = payload.expected_child_count,
        completed_child_count = payload.completed_child_count,
      },
    },
    old_inputs = {
      current_fact = {
        state = "blocked",
        version = VERSION,
        stage_rank = devloop_state.stage_rank("blocked"),
      },
      caller_from_states = json_array({ "blocked" }),
      incoming_version = event.payload.dedup_key,
      target_version = payload.dedup_key,
      handoff_reference = JSON_NULL,
    },
    old_outcome = {
      status = "raised",
      reason_code = "decomposed-children-missing",
      cas_outcome = decision.outcome,
      emitted_effects = json_array({
        {
          effect_id = "queue:" .. DECOMPOSE_QUEUE,
          sink_kind = "queue",
          authority_class = "grantless-published-intent",
          ordinal = 1,
        },
      }),
      observable_writes = json_array({
        {
          effect_id = "queue:" .. DECOMPOSE_QUEUE,
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
        ref = "devloop.logging.log_raise:observe_issue:" .. DECOMPOSE_QUEUE,
      },
      {
        kind = "production-callsite",
        ref = "packages/github-devloop/departments/observe_issue/main.lua:568-780",
      },
      {
        kind = "production-condition",
        ref = "libraries/devloop/replayer.lua:472-509",
      },
      {
        kind = "production-payload-constructor",
        ref = "libraries/devloop/decompose.lua:218-244",
      },
      {
        kind = "sink-inventory",
        ref = "packages/github-devloop/core/restart/sink_inventory.lua",
      },
    }),
  }
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
    if is_target_record(record) then table.insert(selected, record) end
  end
  return selected
end

return {
  test_observe_issue_decompose_published_intent_is_one_collapsed_runtime_disposition = function()
    local first = json_array({ build_record() })
    local second = json_array({ build_record() })
    local repeat_difference = first_difference(
      second,
      first,
      "old_behavior_observations[observe-issue-decompose-intent][repeat]"
    )
    if repeat_difference ~= nil or canonical_json(second) ~= canonical_json(first) then
      error("second OLD published-intent runtime capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
    end

    local expected = committed_records()
    t.eq(#first, 1, "payload parameter variance collapses to one OWN disposition")
    if #expected ~= 1 then
      error("inventory must contain exactly one collapsed disposition; runtime_records=" .. canonical_json(first), 0)
    end
    local inventory_difference = first_difference(
      first,
      expected,
      "old_behavior_observations[observe-issue-decompose-intent]"
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
