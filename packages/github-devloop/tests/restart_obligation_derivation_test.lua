local h = require("tests.devloop_core_helpers")
local owner_projection = require("devloop.restart_owner_pending_projection")
local restart_obligations = require("devloop.restart_obligations")

local OWNER = "github-devloop"
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local exemplars = {
  require("core.restart.issue_reconcile_obligations")[1],
  require("core.restart.timeout_obligations")[1],
}

local t = h.t

local function canonical_edges()
  return owner_projection.edges(OWNER, h.core.restart_transition_table(), inventories)
end

local function witness_index_without(excluded_edge_id)
  local result = {}
  for _, exemplar in ipairs(exemplars) do
    if exemplar.edge_id ~= excluded_edge_id then
      result[exemplar.edge_id] = exemplar
    end
  end
  return result
end

local function pending_witness_index_without(edges, excluded_edge_id)
  local result = owner_projection.frozen_pending_witness_index(OWNER, edges)
  if excluded_edge_id ~= nil then
    result[excluded_edge_id] = nil
  end
  return result
end

local function entitlement_witness_index_without(edges, excluded_edge_id)
  local result = owner_projection.frozen_entitlement_witness_index(OWNER, edges)
  if excluded_edge_id ~= nil then
    result[excluded_edge_id] = nil
  end
  return result
end

local function timeout_witness_index_without(rows, edges, excluded_edge_id)
  local result = owner_projection.frozen_timeout_witness_index(OWNER, rows, edges)
  if excluded_edge_id ~= nil then
    result[excluded_edge_id] = nil
  end
  return result
end

local function declared_effect_ids(entitlements)
  local result = {}
  local seen = {}
  for _, status in ipairs({ "apply", "idempotent" }) do
    for _, effect_id in ipairs(entitlements[status].effect_ids) do
      if not seen[effect_id] then
        seen[effect_id] = true
        table.insert(result, effect_id)
      end
    end
  end
  return result
end

local function assert_array(actual, expected)
  t.eq(#actual, #expected)
  for index, value in ipairs(expected) do
    t.eq(actual[index], value)
  end
end

local function index_by_edge(entries)
  local result = {}
  for _, entry in ipairs(entries) do
    result[entry.edge_id] = entry
  end
  return result
end

return {
  test_issue_owner_derives_cas_admission_obligations_from_canonical_edges = function()
    local edges = canonical_edges()
    local witnesses = witness_index_without(nil)
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
    t.eq(#result.obligations, #exemplars)
  end,

  test_issue_owner_reports_removed_frozen_witness_as_unmapped = function()
    local removed_edge_id = exemplars[1].edge_id
    local result = restart_obligations.derive(
      canonical_edges(),
      witness_index_without(removed_edge_id)
    )
    local unmapped = index_by_edge(result.unmapped)
    t.eq(unmapped[removed_edge_id].reason, "missing-frozen-witness")
  end,

  test_issue_owner_derives_pending_obligations_from_typed_participation = function()
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

    t.eq(participating_count, 19)
    t.eq(#result.obligations, participating_count)
    t.eq(#result.unmapped, 0)
  end,

  test_issue_owner_reports_removed_frozen_pending_witness_as_unmapped = function()
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

  test_issue_owner_derives_entitlement_obligations_from_typed_entitlements = function()
    local edges = canonical_edges()
    local witnesses = entitlement_witness_index_without(edges, nil)
    local result = restart_obligations.derive_entitlement(edges, witnesses)
    local derived = index_by_edge(result.obligations)
    local unmapped = index_by_edge(result.unmapped)
    local entitlement_count = 0

    for _, edge in ipairs(edges) do
      local entitlements = edge.transition_effect_entitlements
      if type(entitlements) == "table" and next(entitlements) ~= nil then
        entitlement_count = entitlement_count + 1
        local witness = witnesses[edge.id]
        local obligation = derived[edge.id]
        t.is_true(witness ~= nil)
        t.is_true(obligation ~= nil)
        t.eq(obligation.obligation_id, edge.id .. "/effect-entitlement")
        t.eq(obligation.owner, edge.owner)
        t.eq(obligation.case_kind, "entitlement")
        t.eq(obligation.input_fixture_id, witness.input_fixture_id)
        t.eq(obligation.witness_id, witness.witness_id)
        t.eq(obligation.expected_decision.apply.effect_entitlement_id, entitlements.apply.id)
        assert_array(obligation.expected_decision.apply.granted_effect_ids, entitlements.apply.effect_ids)
        t.eq(obligation.expected_decision.idempotent.effect_entitlement_id, entitlements.idempotent.id)
        assert_array(obligation.expected_decision.idempotent.granted_effect_ids, entitlements.idempotent.effect_ids)
        assert_array(obligation.expected_effect_ids, declared_effect_ids(entitlements))
        t.eq(obligation.expected_payload_obligations, witness.expected_payload_obligations)
        t.eq(unmapped[edge.id], nil)
      else
        t.eq(derived[edge.id], nil)
        t.eq(unmapped[edge.id], nil)
      end
    end

    t.is_true(entitlement_count > 0)
    t.eq(#result.obligations, entitlement_count)
    t.eq(#result.unmapped, 0)
  end,

  test_issue_owner_reports_removed_frozen_entitlement_witness_as_unmapped = function()
    local edges = canonical_edges()
    local removed_edge_id = nil
    for _, edge in ipairs(edges) do
      local entitlements = edge.transition_effect_entitlements
      if type(entitlements) == "table" and next(entitlements) ~= nil then
        removed_edge_id = edge.id
        break
      end
    end
    local result = restart_obligations.derive_entitlement(
      edges,
      entitlement_witness_index_without(edges, removed_edge_id)
    )
    local unmapped = index_by_edge(result.unmapped)
    t.eq(unmapped[removed_edge_id].reason, "missing-frozen-witness")
  end,

  test_issue_owner_derives_timeout_obligations_from_typed_resolver = function()
    local rows = h.core.restart_transition_table()
    local edges = owner_projection.edges(OWNER, rows, inventories)
    local witnesses = timeout_witness_index_without(rows, edges, nil)
    local result = restart_obligations.derive_timeout(edges, witnesses)
    local derived = index_by_edge(result.obligations)
    local unmapped = index_by_edge(result.unmapped)
    local rows_by_id = {}
    local timeout_count = 0

    for _, row in ipairs(rows) do
      rows_by_id[row.from_state] = row
    end
    for _, edge in ipairs(edges) do
      if edge.timeout_evidence_policy_id ~= nil then
        timeout_count = timeout_count + 1
        local witness = witnesses[edge.id]
        local obligation = derived[edge.id]
        t.is_true(witness ~= nil)
        t.is_true(obligation ~= nil)
        t.eq(obligation.obligation_id, edge.id .. "/timeout-resolver")
        t.eq(obligation.owner, edge.owner)
        t.eq(obligation.case_kind, "timeout")
        t.eq(obligation.input_fixture_id, witness.input_fixture_id)
        t.eq(obligation.witness_id, witness.witness_id)
        t.eq(
          obligation.expected_decision.actionable_epoch_source,
          rows_by_id[edge.row_id].actionable_epoch.source
        )
        t.eq(obligation.expected_decision.resolver, edge.timeout_evidence_policy_id)
        t.eq(obligation.expected_effect_ids, witness.expected_effect_ids)
        t.eq(obligation.expected_payload_obligations, witness.expected_payload_obligations)
        t.eq(unmapped[edge.id], nil)
      else
        t.eq(derived[edge.id], nil)
        t.eq(unmapped[edge.id], nil)
      end
    end

    t.eq(timeout_count, 1)
    t.eq(#result.obligations, timeout_count)
    t.eq(#result.unmapped, 0)
  end,

  test_issue_owner_reports_removed_frozen_timeout_witness_as_unmapped = function()
    local rows = h.core.restart_transition_table()
    local edges = owner_projection.edges(OWNER, rows, inventories)
    local removed_edge_id = nil
    for _, edge in ipairs(edges) do
      if edge.timeout_evidence_policy_id ~= nil then
        removed_edge_id = edge.id
        break
      end
    end
    local result = restart_obligations.derive_timeout(
      edges,
      timeout_witness_index_without(rows, edges, removed_edge_id)
    )
    local unmapped = index_by_edge(result.unmapped)
    t.eq(unmapped[removed_edge_id].reason, "missing-frozen-witness")
  end,
}
