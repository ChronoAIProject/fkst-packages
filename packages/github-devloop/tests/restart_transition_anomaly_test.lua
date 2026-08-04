local h = require("tests.devloop_core_helpers")
local anomaly = require("devloop.restart_transition_anomaly")
local issue_analysis = require("core.restart_analysis")

local t = h.t

local OWNER = "github-devloop"
local ENTITY = { kind = "issue", repo = "owner/repo", number = 42 }
local EDGE_ID = OWNER .. "/thinking/autonomous/consensus-reached"
local CAS_POLICY_ID = "cas.legacy_consensus_result_v1"

local rows = {
  {
    from_state = "thinking",
    responsibility_signature = {
      successors = {
        {
          state = "ready",
          kind = "autonomous",
          output_variant = "consensus-reached",
          cas_policy_id = CAS_POLICY_ID,
          transition_effect_entitlements = {
            apply = { id = EDGE_ID .. "/apply", effect_ids = {} },
            idempotent = { id = EDGE_ID .. "/idempotent", effect_ids = {} },
          },
        },
      },
    },
  },
  {
    from_state = "ready",
    responsibility_signature = { successors = {} },
  },
}

local function marker(state, order, evidence_ref)
  return {
    state = state,
    order = order,
    generation = "generation:7",
    epoch = "epoch:11",
    evidence_ref = evidence_ref,
  }
end

local function transition(overrides)
  local value = {
    observed_from = "thinking",
    observed_target = "ready",
    edge_kind = "autonomous",
    edge_id = EDGE_ID,
    cas_policy_id = CAS_POLICY_ID,
    cause_status = "complete",
    evidence_refs = { "cause:consensus-reached" },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function evidence(transitions)
  return {
    owner = OWNER,
    entity = ENTITY,
    transitions = transitions,
  }
end

local function ordered_history(target)
  return {
    marker("thinking", 1, "marker:thinking"),
    marker(target or "ready", 2, "marker:" .. (target or "ready")),
  }
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[copy(key)] = copy(item)
  end
  return result
end

local function deep_equal(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not deep_equal(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function assert_anomaly(value, disposition, reason_code)
  t.eq(#value, 1, disposition .. " anomaly count")
  local item = value[1]
  t.eq(item.schema, "restart-transition-anomaly.v1")
  t.eq(item.owner, OWNER)
  t.eq(item.entity.kind, "issue")
  t.eq(item.entity.repo, "owner/repo")
  t.eq(item.entity.number, 42)
  t.eq(item.disposition, disposition)
  t.eq(item.reason_code, reason_code)
  return item
end

return {
  test_schema_v1_and_fully_supported_history_are_empty = function()
    local schema = anomaly.schema()
    t.eq(schema.schema, "restart-transition-anomaly.v1")
    t.eq(schema.dispositions["illegal-transition"], true)
    t.eq(schema.dispositions["malformed-evidence"], true)
    t.eq(schema.dispositions["ordering-indeterminate"], true)
    t.eq(schema.dispositions["cause-indeterminate"], true)

    local result = anomaly.analyze_observed_transition_history(
      rows,
      ordered_history(),
      evidence({ transition() })
    )
    t.eq(#result, 0, "fully supported explicit transition history")
  end,

  test_unsupported_explicit_edge_is_illegal_transition = function()
    local result = anomaly.analyze_observed_transition_history(
      rows,
      ordered_history("blocked"),
      evidence({ transition({
        observed_target = "blocked",
        edge_id = OWNER .. "/thinking/autonomous/not-declared",
        cas_policy_id = nil,
      }) })
    )
    local item = assert_anomaly(result, "illegal-transition", "unsupported-explicit-edge")
    t.eq(item.observed_from, "thinking")
    t.eq(item.observed_target, "blocked")
    t.eq(item.edge_kind, "autonomous")
    t.eq(item.decision_status, "illegal")
    t.eq(item.cause_status, "complete")
    t.eq(item.ordering_status, "complete")
  end,

  test_invalid_marker_evidence_is_malformed = function()
    local history = ordered_history()
    history[2].state = nil
    local result = anomaly.analyze_observed_transition_history(
      rows,
      history,
      evidence({ transition() })
    )
    local item = assert_anomaly(result, "malformed-evidence", "marker-state-invalid")
    t.eq(item.decision_status, "invalid")
    t.eq(item.cause_status, "invalid")
  end,

  test_duplicate_and_out_of_order_history_are_ordering_indeterminate = function()
    local duplicate = ordered_history()
    duplicate[2].order = 1
    local duplicate_result = anomaly.analyze_observed_transition_history(
      rows,
      duplicate,
      evidence({ transition() })
    )
    local duplicate_item = assert_anomaly(
      duplicate_result,
      "ordering-indeterminate",
      "duplicate-marker-order"
    )
    t.eq(duplicate_item.ordering_status, "indeterminate")

    local out_of_order = ordered_history()
    out_of_order[1].order = 2
    out_of_order[2].order = 1
    local out_of_order_result = anomaly.analyze_observed_transition_history(
      rows,
      out_of_order,
      evidence({ transition() })
    )
    local out_of_order_item = assert_anomaly(
      out_of_order_result,
      "ordering-indeterminate",
      "out-of-order-marker-history"
    )
    t.eq(out_of_order_item.ordering_status, "indeterminate")
  end,

  test_missing_order_and_cause_are_honestly_indeterminate = function()
    local unordered = ordered_history()
    unordered[1].order = nil
    unordered[2].order = nil
    local ordering_result = anomaly.analyze_observed_transition_history(
      rows,
      unordered,
      evidence({ transition() })
    )
    local ordering_item = assert_anomaly(
      ordering_result,
      "ordering-indeterminate",
      "ordering-evidence-insufficient"
    )
    t.eq(ordering_item.decision_status, "indeterminate")

    local cause_result = anomaly.analyze_observed_transition_history(
      rows,
      ordered_history(),
      evidence({ transition({ cause_status = "incomplete", evidence_refs = {} }) })
    )
    local cause_item = assert_anomaly(
      cause_result,
      "cause-indeterminate",
      "cause-evidence-insufficient"
    )
    t.eq(cause_item.cause_status, "incomplete")
    t.eq(cause_item.ordering_status, "complete")
    t.eq(cause_item.decision_status, "indeterminate")
  end,

  test_issue_owner_binder_uses_issue_rows_only = function()
    local result = issue_analysis.analyze_observed_transition_history(
      ordered_history("not-an-issue-state"),
      evidence({ transition({
        observed_target = "not-an-issue-state",
        edge_id = OWNER .. "/thinking/autonomous/not-an-issue-state",
        cas_policy_id = nil,
      }) })
    )
    local item = assert_anomaly(result, "illegal-transition", "unsupported-explicit-edge")
    t.eq(item.owner, "github-devloop")
  end,

  test_analysis_does_not_mutate_inputs = function()
    local input_rows = copy(rows)
    local input_history = ordered_history()
    local input_evidence = evidence({ transition() })
    local expected_rows = copy(input_rows)
    local expected_history = copy(input_history)
    local expected_evidence = copy(input_evidence)

    anomaly.analyze_observed_transition_history(input_rows, input_history, input_evidence)

    t.is_true(deep_equal(input_rows, expected_rows), "canonical rows remain byte-shaped")
    t.is_true(deep_equal(input_history, expected_history), "marker history remains byte-shaped")
    t.is_true(deep_equal(input_evidence, expected_evidence), "observed evidence remains byte-shaped")
  end,
}
