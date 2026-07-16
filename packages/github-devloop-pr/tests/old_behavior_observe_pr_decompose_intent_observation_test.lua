local config = require("devloop.config")
local decompose_lib = require("devloop.decompose")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local observation_support = require("testkit.old_behavior_observation_support")
local testing = require("testkit.testing")
local observe_pr_department = require("departments.observe_pr.main")

local t = h.t
local core = h.core
local JSON_NULL = observation_support.JSON_NULL
local canonical_json = observation_support.canonical_json
local copy_value = observation_support.copy_value
local first_difference = observation_support.first_difference
local json_array = observation_support.json_array
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local DECOMPOSE_QUEUE = "github-devloop-decompose.devloop_decompose"
local OBSERVATION_PREFIX = "intent:github-devloop-pr:observe-pr-decompose/"
local SITE = {
  path = "packages/github-devloop-pr/departments/observe_pr/main.lua",
  symbol = "process_pr_event",
  ordinal = DECOMPOSE_QUEUE,
}

local REPO = "owner/repo"
local BASE_BRANCH = "dev"
local HEAD_SHA = "def456"

local function tuple_key(family, expected_count, completed_count)
  return tostring(family)
    .. "/expected-" .. tostring(expected_count)
    .. "/completed-" .. tostring(completed_count)
end

local function production_fixture_lattice()
  local fixtures = json_array()
  local ordinal = 0
  for _, family in ipairs({ "bound", "unbound" }) do
    for expected_count = 1, decompose_lib.max_decompose_issues() do
      for completed_count = 0, expected_count - 1 do
        ordinal = ordinal + 1
        local issue_number = 4200 + ordinal
        local pr_number = 7000 + ordinal
        local proposal_id = "github-devloop/issue/owner/repo/" .. tostring(issue_number)
        local version = "ready/consensus-" .. proposal_id .. "/2026-06-03T01-02-03Z/fix/1/fix/2/fix/3"
        local review_proposal_id = devloop_base.pr_review_proposal_id(REPO, pr_number, version, HEAD_SHA)
        table.insert(fixtures, {
          family = family,
          expected_count = expected_count,
          completed_count = completed_count,
          name = tuple_key(family, expected_count, completed_count),
          issue_number = issue_number,
          pr_number = pr_number,
          proposal_id = proposal_id,
          branch = "devloop-owner-repo-" .. tostring(issue_number) .. "-01HY",
          version = version,
          review_proposal_id = review_proposal_id,
          review_dedup_key = "consensus:" .. review_proposal_id .. "/review",
          source_ref = { kind = "external", ref = "owner/repo#pr/" .. tostring(pr_number) },
        })
      end
    end
  end
  table.sort(fixtures, function(left, right) return left.name < right.name end)
  return fixtures
end

local function event_for(fixture)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = REPO,
      number = fixture.pr_number,
      state = "OPEN",
      updated_at = "2026-06-04T01:02:03Z",
      dedup_key = "owner/repo#pr#" .. tostring(fixture.pr_number) .. "@2026-06-04T01:02:03Z/" .. fixture.name,
      source_ref = copy_value(fixture.source_ref),
    },
    now_seconds = 1784048400,
  }
end

local function fixture_comments(fixture)
  local comments = json_array({
    m_builders.pr_origin_marker(fixture.proposal_id, tostring(fixture.issue_number), fixture.branch, fixture.version, BASE_BRANCH),
    core.build_fix_reconcile_comment_request(REPO, tostring(fixture.issue_number), {
      proposal_id = fixture.proposal_id,
      issue_version = fixture.version,
      dedup_key = "fix-reconcile:" .. fixture.version,
      source_ref = copy_value(fixture.source_ref),
    }, "drop", "fix-loop-max-rounds-after-3-rounds").body,
  })
  if fixture.family == "bound" then
    table.insert(comments, m_builders.merge_gate_marker(
      fixture.proposal_id,
      fixture.pr_number,
      fixture.version,
      fixture.review_proposal_id,
      fixture.review_dedup_key,
      HEAD_SHA,
      nil,
      "rollup-red"
    ))
  end
  table.insert(comments, decompose_lib.decomposed_marker(
    fixture.proposal_id,
    fixture.version,
    fixture.pr_number,
    fixture.expected_count
  ))
  return comments
end

local function child_issue_stdout(fixture)
  local rendered = {}
  for index = 1, fixture.completed_count do
    table.insert(rendered, string.format(
      '{"number":%d,"title":"Child %d","state":"OPEN","author":{"login":"fkst-test-bot"},"body":"%s","url":"https://github.example/owner/repo/issues/%d"}',
      100 + index,
      index,
      h.json_string(decompose_lib.decompose_child_marker(fixture.proposal_id, fixture.version, fixture.pr_number, index)),
      100 + index
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]\n"
end

local function prepare_fixture(fixture)
  h.mock_bot_env()
  entity_read_mocks.mock_pr_read_forms(t, {
    repo = REPO,
    number = fixture.pr_number,
    comments = fixture_comments(fixture),
    head = fixture.branch,
    head_sha = HEAD_SHA,
    state = "OPEN",
    base_branch = BASE_BRANCH,
    labels = { "fkst-dev:blocked" },
    times = 1,
  })
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = REPO,
    number = fixture.issue_number,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "assignees,author", 1)
  t.mock_command(core.gh_issue_list_decompose_children_cmd(REPO, fixture.proposal_id), {
    stdout = child_issue_stdout(fixture),
    stderr = "",
    exit_code = 0,
  })
end

local function only_decompose_raise(raises, label)
  local selected = json_array()
  for _, raised in ipairs(raises or {}) do
    if raised.queue == DECOMPOSE_QUEUE then
      table.insert(selected, raised)
    end
  end
  t.eq(#selected, 1, label .. " contains exactly one decompose intent")
  return selected[1]
end

local function capture_runtime(fixture)
  local event = event_for(fixture)
  prepare_fixture(fixture)
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
      dept = "observe_pr",
      from_state = "blocked",
      write_mode = "real",
      run = function()
        return testing.run_fake(observe_pr_department, event)
      end,
      codex_runs_for_read = json_array(),
    })
    return run_result, run_capture
  end)
  decompose_lib.build_decompose_replay_payload = original_builder
  if not ok then
    error(result, 0)
  end

  t.eq(#constructor_payloads, 1, fixture.name .. ": real observe_pr dispatch calls the replay constructor once")
  t.eq(#captured.raises, #result.raises, fixture.name .. ": raise spy and run_fake raise counts")
  local emitted = only_decompose_raise(result.raises, fixture.name .. " run_fake emitted raises")
  local spied = only_decompose_raise(captured.raises, fixture.name .. " raise-spy captures")
  t.eq(spied.queue, emitted.queue, fixture.name .. ": raise spy captures the emitted queue")
  t.eq(canonical_json(spied.payload), canonical_json(emitted.payload), fixture.name .. ": raise spy captures the complete emitted payload")
  t.eq(canonical_json(spied.payload), canonical_json(constructor_payloads[1]), fixture.name .. ": published intent exactly matches the direct constructor variant")
  t.eq(#captured.decisions, 1, fixture.name .. ": blocked replay records one routing decision")
  t.eq(captured.decisions[1].outcome, "applied(decomposed-children-missing)", fixture.name .. ": blocked replay reaches the decompose raise")
  return event, copy_value(spied), captured.decisions[1]
end

local function review_binding(payload)
  if payload.review_proposal_id == nil then
    return JSON_NULL
  end
  return {
    review_proposal_id = payload.review_proposal_id,
    review_dedup_key = payload.review_dedup_key,
    head_sha = payload.head_sha,
  }
end

local function build_record(fixture)
  local event, raised, decision = capture_runtime(fixture)
  local payload = raised.payload
  t.eq(payload.expected_child_count, fixture.expected_count, fixture.name .. ": expected child count")
  t.eq(payload.completed_child_count, fixture.completed_count, fixture.name .. ": completed child count")
  t.eq(payload.review_proposal_id ~= nil, fixture.family == "bound", fixture.name .. ": review binding family")
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = OBSERVATION_PREFIX .. fixture.name,
    owner = "github-devloop-pr",
    site = copy_value(SITE),
    boundary = "published_intent_producer",
    typed_intent = {
      kind = "published_intent",
      source_state = "blocked",
      source_boundary = event.queue,
      target = raised.queue,
      cause_schema_id = event.payload.schema,
      generation_epoch = {
        current_version = fixture.version,
        source_version = event.payload.dedup_key,
        payload_version = payload.dedup_key,
      },
      lineage = {
        proposal_id = payload.proposal_id,
        pr_number = payload.pr_number,
        source_ref = copy_value(payload.source_ref),
        expected_child_count = payload.expected_child_count,
        completed_child_count = payload.completed_child_count,
        review_binding = copy_value(review_binding(payload)),
      },
    },
    old_inputs = {
      current_fact = {
        state = "blocked",
        version = fixture.version,
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
        ref = "devloop.logging.log_raise:observe_pr:" .. DECOMPOSE_QUEUE,
      },
      {
        kind = "production-callsite",
        ref = "packages/github-devloop-pr/departments/observe_pr/main.lua:539-577",
      },
      {
        kind = "production-condition",
        ref = "libraries/devloop/replayer.lua:472-509",
      },
      {
        kind = "production-payload-lattice",
        ref = "libraries/devloop/decompose.lua:208-244",
      },
      {
        kind = "production-pr-marker-writer",
        ref = "packages/github-devloop-decompose/departments/decompose/main.lua:216-235",
      },
    }),
  }
end

local function fixture_tuple_set(fixtures)
  local tuples = {}
  for _, fixture in ipairs(fixtures) do
    if tuples[fixture.name] ~= nil then
      error("duplicate fixture tuple: " .. fixture.name, 0)
    end
    tuples[fixture.name] = true
  end
  return tuples
end


local function record_tuple(record, label)
  local lineage = record.typed_intent and record.typed_intent.lineage or {}
  local family = lineage.review_binding == JSON_NULL and "unbound" or "bound"
  local tuple = tuple_key(family, lineage.expected_child_count, lineage.completed_child_count)
  if tuple:find("nil", 1, true) ~= nil then
    error(label .. " has incomplete tuple fields: " .. canonical_json(record), 0)
  end
  return tuple
end

local function record_tuple_set(records, label)
  local tuples = {}
  for index, record in ipairs(records) do
    local tuple = record_tuple(record, label .. "[" .. tostring(index) .. "]")
    if tuples[tuple] ~= nil then
      error(label .. " contains duplicate tuple " .. tuple, 0)
    end
    tuples[tuple] = true
  end
  return tuples
end

local function assert_bidirectional_tuple_membership(actual, expected, actual_label, expected_label, actual_records)
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

local function runtime_records(fixtures)
  local records = json_array()
  for _, fixture in ipairs(fixtures) do
    table.insert(records, build_record(fixture))
  end
  table.sort(records, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  return records
end

return {
  test_observe_pr_decompose_published_intent_is_real_dispatch_and_bidirectional = function()
    local fixtures = production_fixture_lattice()
    local fixture_tuples = fixture_tuple_set(fixtures)
    local first = runtime_records(fixtures)
    local second = runtime_records(fixtures)
    local repeat_difference = first_difference(
      second,
      first,
      "old_behavior_observations[observe-pr-decompose-intent][repeat]"
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
      "old_behavior_observations[observe-pr-decompose-intent]"
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
