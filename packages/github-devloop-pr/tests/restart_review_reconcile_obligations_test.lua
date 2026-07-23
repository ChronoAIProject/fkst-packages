local obligations = require("core.restart.review_reconcile_obligations")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local h = require("tests.devloop_core_helpers")

local t = h.t
local OWNER = "github-devloop-pr"
local EDGE_ID = OWNER .. "/reviewing/entry/review_reconcile_true_stall"
local CORPUS_PATH = "migration/restart-lifecycle.inventory.json"
local SITE = {
  path = "packages/github-devloop-pr/departments/reconcile/main.lua",
  symbol = "pipeline_review",
  ordinal = "versioned_transition_status:reviewing->blocked",
}

local function is_frozen_record(record)
  local site = type(record) == "table" and record.site or nil
  return type(site) == "table"
    and site.path == SITE.path
    and site.symbol == SITE.symbol
    and site.ordinal == SITE.ordinal
end

local function frozen_records()
  local inventory = json.decode(file.read(CORPUS_PATH))
  local records = {}
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if is_frozen_record(record) then
      records[#records + 1] = record
    end
  end
  table.sort(records, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  return records
end

local function index_by_reason(records)
  local result = {}
  for _, record in ipairs(records) do
    result[record.old_outcome.reason_code] = record
  end
  return result
end

local function review_reconcile_edge()
  local edges = owner_pending_projection.edges(
    OWNER,
    h.core.restart_transition_table(),
    {
      canonicalization = require("core.restart.canonicalization_inventory"),
      entry = require("core.restart.entry_inventory"),
      operator_reentry = require("core.restart.operator_reentry_inventory"),
    }
  )
  for _, edge in ipairs(edges) do
    if edge.id == EDGE_ID then
      return edge
    end
  end
  error("restart review reconcile obligations: entry edge is missing", 0)
end

local NORMALIZED_STATUS = {
  apply = "apply",
  ["already-terminal"] = "idempotent",
  ["review-reconcile-marker-visible"] = "idempotent",
  ["state-advanced"] = "stale",
}

return {
  test_review_reconcile_obligations_link_pr_owner_edge_to_frozen_old_matrix = function()
    local records = frozen_records()
    local frozen = index_by_reason(records)
    local edge = review_reconcile_edge()

    t.eq(#records, 4, "review reconcile frozen OLD observation count")
    t.eq(#obligations, #records)
    t.eq(edge.source.state, "reviewing")
    t.eq(edge.source.boundary, "devloop_review_reconcile")
    t.eq(edge.target, "blocked")

    for _, obligation in ipairs(obligations) do
      local fixture_id = obligation.input_fixture_id
      local record = frozen[fixture_id]
      t.is_true(record ~= nil, obligation.obligation_id .. ": frozen witness fixture")
      t.eq(obligation.owner, OWNER, obligation.obligation_id .. ": owner")
      t.eq(obligation.edge_id, edge.id, obligation.obligation_id .. ": edge")
      t.eq(obligation.case_kind, "cas-matrix", obligation.obligation_id .. ": case kind")
      t.eq(
        obligation.expected_decision.cas_status,
        NORMALIZED_STATUS[record.old_outcome.reason_code],
        obligation.obligation_id .. ": normalized authority status"
      )
      t.eq(
        obligation.expected_decision.frozen_status,
        record.old_outcome.status,
        obligation.obligation_id .. ": frozen status"
      )
      t.eq(
        obligation.expected_decision.frozen_reason_code,
        record.old_outcome.reason_code,
        obligation.obligation_id .. ": frozen reason"
      )
      t.eq(
        obligation.expected_decision.frozen_cas_outcome,
        record.old_outcome.cas_outcome,
        obligation.obligation_id .. ": frozen CAS outcome"
      )
      t.eq(#obligation.expected_effect_ids, #record.old_outcome.observable_writes)
      for ordinal, effect_id in ipairs(obligation.expected_effect_ids) do
        t.eq(effect_id, record.old_outcome.observable_writes[ordinal].queue)
      end
      t.eq(#obligation.expected_payload_obligations, #obligation.expected_effect_ids)
      for ordinal, payload_obligation in ipairs(obligation.expected_payload_obligations) do
        t.eq(payload_obligation.effect_id, obligation.expected_effect_ids[ordinal])
        t.eq(payload_obligation.equality, "byte-exact-frozen-old")
      end
      t.eq(
        obligation.witness_id,
        CORPUS_PATH .. "#" .. record.observation_id,
        obligation.obligation_id .. ": witness"
      )
    end
  end,
}
