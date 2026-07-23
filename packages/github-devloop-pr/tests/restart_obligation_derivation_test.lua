local h = require("tests.devloop_core_helpers")
local owner_projection = require("devloop.restart_owner_pending_projection")
local restart_obligations = require("devloop.restart_obligations")
local restart_cas_catalog = require("devloop.restart_cas_catalog")

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

local function edge_witness_index_without(edges, excluded_edge_id)
  local result = owner_projection.frozen_edge_witness_index(OWNER, edges)
  if excluded_edge_id ~= nil then
    result[excluded_edge_id] = nil
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

local function family_variant_witness_index_without(edges, excluded_edge_id)
  local result = owner_projection.frozen_family_variant_witness_index(OWNER, edges)
  if excluded_edge_id ~= nil then
    result[excluded_edge_id] = nil
  end
  return result
end

local function family_variant_groups(edges)
  local groups = {}
  for _, edge in ipairs(edges) do
    if type(edge.cas_policy_id) == "string" and edge.cas_policy_id ~= ""
        and type(edge.cas_variant) == "string" and edge.cas_variant ~= "" then
      local variants = groups[edge.cas_policy_id]
      if variants == nil then
        variants = {}
        groups[edge.cas_policy_id] = variants
      end
      variants[edge.cas_variant] = true
    end
  end
  return groups
end

local function is_family_variant_edge(edge, groups)
  local variants = groups[edge.cas_policy_id]
  if variants == nil or variants[edge.cas_variant] ~= true then
    return false
  end
  local count = 0
  for _ in pairs(variants) do
    count = count + 1
  end
  return count > 1
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

local function edge_pair_key(edge_a_id, edge_b_id)
  return edge_a_id .. "\n" .. edge_b_id
end

local function compatible_edge_pairs(edges)
  local result = {}
  for _, edge_a in ipairs(edges) do
    for _, edge_b in ipairs(edges) do
      local pending_order = edge_b.pending_order
      if edge_a.id ~= edge_b.id
          and edge_a.owner == edge_b.owner
          and type(pending_order) == "table"
          and edge_a.target == pending_order.predecessor_state then
        table.insert(result, { edge_a = edge_a, edge_b = edge_b })
      end
    end
  end
  return result
end

local function index_by_edge_pair(entries)
  local result = {}
  for _, entry in ipairs(entries) do
    result[edge_pair_key(entry.edge_a_id, entry.edge_b_id)] = entry
  end
  return result
end

return {
  test_pr_owner_derives_one_edge_obligation_per_canonical_edge = function()
    local edges = canonical_edges()
    local witnesses = edge_witness_index_without(edges, nil)
    local result = restart_obligations.derive_edge(edges, witnesses)
    local derived = index_by_edge(result.obligations)
    local unmapped = index_by_edge(result.unmapped)

    for _, edge in ipairs(edges) do
      local witness = witnesses[edge.id]
      local obligation = derived[edge.id]
      t.is_true(witness ~= nil)
      t.is_true(obligation ~= nil)
      t.eq(witness.edge_id, edge.id)
      t.eq(witness.predecessor_state, edge.pending_order.predecessor_state)
      t.eq(witness.target, edge.target)
      t.eq(witness.kind, edge.kind)
      t.eq(obligation.obligation_id, edge.id .. "/edge")
      t.eq(obligation.owner, edge.owner)
      t.eq(obligation.edge_id, edge.id)
      t.eq(obligation.case_kind, "edge")
      t.eq(obligation.input_fixture_id, witness.input_fixture_id)
      t.eq(obligation.witness_id, witness.witness_id)
      t.eq(obligation.expected_decision.predecessor_state, edge.pending_order.predecessor_state)
      t.eq(obligation.expected_decision.target, edge.target)
      t.eq(obligation.expected_decision.kind, edge.kind)
      t.eq(obligation.expected_effect_ids, witness.expected_effect_ids)
      t.eq(obligation.expected_payload_obligations, witness.expected_payload_obligations)
      t.eq(unmapped[edge.id], nil)
    end

    t.eq(#result.obligations, #edges)
    t.eq(#result.unmapped, 0)
  end,

  test_pr_owner_reports_removed_frozen_edge_witness_as_unmapped = function()
    local edges = canonical_edges()
    local removed_edge_id = edges[1].id
    local result = restart_obligations.derive_edge(
      edges,
      edge_witness_index_without(edges, removed_edge_id)
    )
    local derived = index_by_edge(result.obligations)
    local unmapped = index_by_edge(result.unmapped)
    t.eq(unmapped[removed_edge_id].reason, "missing-frozen-witness")
    t.eq(derived[removed_edge_id], nil)
    t.eq(#result.obligations + #result.unmapped, #edges)
  end,

  test_pr_owner_derives_compatible_ordered_typed_edge_pair_obligations = function()
    local edges = canonical_edges()
    local pairs = compatible_edge_pairs(edges)
    local witnesses = edge_witness_index_without(edges, nil)
    local result = restart_obligations.derive_edge_pair(edges, witnesses)
    local derived = index_by_edge_pair(result.obligations)
    local unmapped = index_by_edge_pair(result.unmapped)

    t.is_true(#pairs > 0)
    t.is_true(#pairs < (#edges * (#edges - 1)))
    for _, pair in ipairs(pairs) do
      local edge_a = pair.edge_a
      local edge_b = pair.edge_b
      local key = edge_pair_key(edge_a.id, edge_b.id)
      local obligation = derived[key]
      t.is_true(obligation ~= nil)
      t.eq(obligation.obligation_id, edge_a.id .. "/then/" .. edge_b.id .. "/edge-pair")
      t.eq(obligation.owner, OWNER)
      t.eq(obligation.edge_id, edge_a.id .. "/then/" .. edge_b.id)
      t.eq(obligation.edge_a_id, edge_a.id)
      t.eq(obligation.edge_b_id, edge_b.id)
      t.eq(obligation.edge_a_kind, edge_a.kind)
      t.eq(obligation.edge_b_kind, edge_b.kind)
      t.eq(obligation.case_kind, "edge-pair")
      t.eq(obligation.expected_decision.edge_a.id, edge_a.id)
      t.eq(obligation.expected_decision.edge_a.kind, edge_a.kind)
      t.eq(obligation.expected_decision.edge_a.cas_policy_id, edge_a.cas_policy_id)
      t.eq(obligation.expected_decision.edge_a.cas_variant, edge_a.cas_variant)
      t.eq(obligation.expected_decision.edge_a.target, edge_a.target)
      t.eq(obligation.expected_decision.edge_b.id, edge_b.id)
      t.eq(obligation.expected_decision.edge_b.kind, edge_b.kind)
      t.eq(obligation.expected_decision.edge_b.cas_policy_id, edge_b.cas_policy_id)
      t.eq(obligation.expected_decision.edge_b.cas_variant, edge_b.cas_variant)
      t.eq(obligation.expected_decision.edge_b.predecessor_state, edge_b.pending_order.predecessor_state)
      t.eq(obligation.input_fixture_id,
        witnesses[edge_a.id].input_fixture_id .. "/then/" .. witnesses[edge_b.id].input_fixture_id)
      t.eq(obligation.member_witness_ids[1], witnesses[edge_a.id].witness_id)
      t.eq(obligation.member_witness_ids[2], witnesses[edge_b.id].witness_id)
      t.eq(obligation.witness_id,
        witnesses[edge_a.id].witness_id .. "/then/" .. witnesses[edge_b.id].witness_id)
      t.eq(obligation.expected_payload_obligations.edge_a,
        witnesses[edge_a.id].expected_payload_obligations)
      t.eq(obligation.expected_payload_obligations.edge_b,
        witnesses[edge_b.id].expected_payload_obligations)
      local expected_effect_index = 1
      for _, member_witness in ipairs({ witnesses[edge_a.id], witnesses[edge_b.id] }) do
        for _, effect_id in ipairs(member_witness.expected_effect_ids) do
          t.eq(obligation.expected_effect_ids[expected_effect_index], effect_id)
          expected_effect_index = expected_effect_index + 1
        end
      end
      t.eq(#obligation.expected_effect_ids, expected_effect_index - 1)
      t.eq(unmapped[key], nil)
    end

    t.eq(#result.obligations, #pairs)
    t.eq(#result.unmapped, 0)
  end,

  test_pr_owner_reports_edge_pair_with_missing_member_witness_as_unmapped = function()
    local edges = canonical_edges()
    local pairs = compatible_edge_pairs(edges)
    local removed_edge_id = pairs[1].edge_a.id
    local result = restart_obligations.derive_edge_pair(
      edges,
      edge_witness_index_without(edges, removed_edge_id)
    )
    local derived = index_by_edge_pair(result.obligations)
    local unmapped = index_by_edge_pair(result.unmapped)
    local selected_key = edge_pair_key(pairs[1].edge_a.id, pairs[1].edge_b.id)

    t.eq(unmapped[selected_key].reason, "missing-frozen-witness")
    t.eq(unmapped[selected_key].missing_edge_ids[1], removed_edge_id)
    t.eq(derived[selected_key], nil)
    t.eq(#result.obligations + #result.unmapped, #pairs)
  end,

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

  test_pr_owner_derives_entitlement_obligations_from_typed_entitlements = function()
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

  test_pr_owner_reports_removed_frozen_entitlement_witness_as_unmapped = function()
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

  test_pr_owner_derives_timeout_obligations_from_typed_resolver = function()
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

    t.eq(timeout_count, 2)
    t.eq(#result.obligations, timeout_count)
    t.eq(#result.unmapped, 0)
  end,

  test_pr_owner_reports_removed_frozen_timeout_witness_as_unmapped = function()
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

  test_pr_owner_derives_family_variant_obligations_from_typed_groups = function()
    local edges = canonical_edges()
    local groups = family_variant_groups(edges)
    local witnesses = family_variant_witness_index_without(edges, nil)
    local result = restart_obligations.derive_family_variant(edges, witnesses)
    local derived = index_by_edge(result.obligations)
    local unmapped = index_by_edge(result.unmapped)
    local applicable_count = 0

    for _, edge in ipairs(edges) do
      if is_family_variant_edge(edge, groups) then
        applicable_count = applicable_count + 1
        local definition = restart_cas_catalog.definition(edge.cas_policy_id)
        local variant = definition and definition.variants
          and definition.variants[edge.cas_variant] or nil
        local witness = witnesses[edge.id]
        local obligation = derived[edge.id]
        t.is_true(variant ~= nil)
        t.is_true(witness ~= nil)
        t.is_true(obligation ~= nil)
        t.eq(witness.family_id, edge.cas_policy_id)
        t.eq(witness.variant, edge.cas_variant)
        assert_array(witness.expected_decision.source_states, variant.source_states)
        t.eq(witness.expected_decision.target_state, variant.target_state)
        t.eq(obligation.obligation_id, edge.id .. "/family-variant")
        t.eq(obligation.owner, edge.owner)
        t.eq(obligation.edge_id, edge.id)
        t.eq(obligation.case_kind, "family-variant")
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

    t.is_true(applicable_count > 0)
    t.eq(#result.obligations, applicable_count)
    t.eq(#result.unmapped, 0)
  end,

  test_pr_owner_reports_removed_frozen_family_variant_witness_as_unmapped = function()
    local edges = canonical_edges()
    local groups = family_variant_groups(edges)
    local removed_edge_id = nil
    for _, edge in ipairs(edges) do
      if is_family_variant_edge(edge, groups) then
        removed_edge_id = edge.id
        break
      end
    end
    t.is_true(removed_edge_id ~= nil)
    local result = restart_obligations.derive_family_variant(
      edges,
      family_variant_witness_index_without(edges, removed_edge_id)
    )
    local derived = index_by_edge(result.obligations)
    local unmapped = index_by_edge(result.unmapped)
    t.eq(unmapped[removed_edge_id].reason, "missing-frozen-witness")
    t.eq(derived[removed_edge_id], nil)
  end,
}
