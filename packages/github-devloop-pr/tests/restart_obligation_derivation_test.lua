local h = require("tests.devloop_core_helpers")
local owner_projection = require("devloop.restart_owner_pending_projection")
local restart_obligations = require("devloop.restart_obligations")

local OWNER = "github-devloop-pr"
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local exemplar = require("core.restart.review_reconcile_obligations")[1]

local t = h.t

local function canonical_edges()
  return owner_projection.edges(OWNER, h.core.restart_transition_table(), inventories)
end

local function witness_index(include_exemplar)
  if not include_exemplar then
    return {}
  end
  return { [exemplar.edge_id] = exemplar }
end

local function pending_witness_index_without(edges, excluded_edge_id)
  local result = owner_projection.frozen_pending_witness_index(OWNER, edges)
  if excluded_edge_id ~= nil then
    result[excluded_edge_id] = nil
  end
  return result
end

local function index_by_edge(entries)
  local result = {}
  for _, entry in ipairs(entries) do
    result[entry.edge_id] = entry
  end
  return result
end

return {
  test_pr_owner_derives_cas_admission_obligations_from_canonical_edges = function()
    local edges = canonical_edges()
    local witnesses = witness_index(true)
    local result = restart_obligations.derive(edges, witnesses)
    local derived = index_by_edge(result.obligations)
    local unmapped = index_by_edge(result.unmapped)
    local cas_edge_count = 0

    for _, edge in ipairs(edges) do
      if edge.cas_policy_id ~= nil then
        cas_edge_count = cas_edge_count + 1
        local witness = witnesses[edge.id]
        if witness == nil then
          t.eq(unmapped[edge.id].reason, "missing-frozen-witness")
          t.eq(derived[edge.id], nil)
        else
          local obligation = derived[edge.id]
          t.is_true(obligation ~= nil)
          t.eq(obligation.obligation_id, edge.id .. "/cas-admission")
          t.eq(obligation.owner, edge.owner)
          t.eq(obligation.case_kind, "cas-matrix")
          t.eq(obligation.input_fixture_id, witness.input_fixture_id)
          t.eq(obligation.witness_id, witness.witness_id)
          t.eq(obligation.expected_decision, witness.expected_decision)
          t.eq(obligation.expected_effect_ids, witness.expected_effect_ids)
          t.eq(obligation.expected_payload_obligations, witness.expected_payload_obligations)
          t.eq(unmapped[edge.id], nil)
        end
      else
        t.eq(derived[edge.id], nil)
        t.eq(unmapped[edge.id], nil)
      end
    end

    t.eq(#result.obligations + #result.unmapped, cas_edge_count)
    t.eq(#result.obligations, 1)
  end,

  test_pr_owner_reports_removed_frozen_witness_as_unmapped = function()
    local result = restart_obligations.derive(canonical_edges(), witness_index(false))
    local unmapped = index_by_edge(result.unmapped)
    t.eq(unmapped[exemplar.edge_id].reason, "missing-frozen-witness")
  end,

  test_pr_owner_derives_pending_obligations_from_typed_participation = function()
    local edges = canonical_edges()
    local witnesses = pending_witness_index_without(edges, nil)
    local result = restart_obligations.derive_pending(edges, witnesses)
    local derived = index_by_edge(result.obligations)
    local unmapped = index_by_edge(result.unmapped)
    local participating_count = 0

    for _, edge in ipairs(edges) do
      if edge.pending_order.participates then
        participating_count = participating_count + 1
        local witness = witnesses[edge.id]
        local obligation = derived[edge.id]
        t.is_true(witness ~= nil)
        t.is_true(obligation ~= nil)
        t.eq(obligation.obligation_id, edge.id .. "/pending-participation")
        t.eq(obligation.owner, edge.owner)
        t.eq(obligation.case_kind, "pending")
        t.eq(obligation.input_fixture_id, witness.input_fixture_id)
        t.eq(obligation.witness_id, witness.witness_id)
        t.eq(obligation.expected_decision, witness.expected_decision)
        t.eq(obligation.expected_effect_ids, witness.expected_effect_ids)
        t.eq(obligation.expected_payload_obligations, witness.expected_payload_obligations)
        t.eq(unmapped[edge.id], nil)
      else
        t.eq(derived[edge.id], nil)
        t.eq(unmapped[edge.id], nil)
      end
    end

    t.eq(participating_count, 17)
    t.eq(#result.obligations, participating_count)
    t.eq(#result.unmapped, 0)
  end,

  test_pr_owner_reports_removed_frozen_pending_witness_as_unmapped = function()
    local edges = canonical_edges()
    local removed_edge_id = nil
    for _, edge in ipairs(edges) do
      if edge.pending_order.participates then
        removed_edge_id = edge.id
        break
      end
    end
    local result = restart_obligations.derive_pending(
      edges,
      pending_witness_index_without(edges, removed_edge_id)
    )
    local unmapped = index_by_edge(result.unmapped)
    t.eq(unmapped[removed_edge_id].reason, "missing-frozen-witness")
  end,
}
