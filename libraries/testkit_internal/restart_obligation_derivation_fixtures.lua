local M = {}

function M.new(deps)
  deps = deps or {}
  local h = deps.h
    or error("testkit_internal.restart_obligation_derivation_fixtures: fixture-dependency-missing: deps.h is required")
  local owner_projection = deps.owner_projection
    or error("testkit_internal.restart_obligation_derivation_fixtures: fixture-dependency-missing: deps.owner_projection is required")
  local restart_obligations = deps.restart_obligations
    or error("testkit_internal.restart_obligation_derivation_fixtures: fixture-dependency-missing: deps.restart_obligations is required")
  local restart_cas_catalog = deps.restart_cas_catalog
    or error("testkit_internal.restart_obligation_derivation_fixtures: fixture-dependency-missing: deps.restart_cas_catalog is required")
  local OWNER = deps.owner
    or error("testkit_internal.restart_obligation_derivation_fixtures: fixture-dependency-missing: deps.owner is required")
  local inventories = deps.inventories
    or error("testkit_internal.restart_obligation_derivation_fixtures: fixture-dependency-missing: deps.inventories is required")
  local LOOP_CLASS_ORDER = deps.loop_class_order
    or error("testkit_internal.restart_obligation_derivation_fixtures: fixture-dependency-missing: deps.loop_class_order is required")

  local t = h.t

local function canonical_edges()
  return owner_projection.edges(OWNER, h.core.restart_transition_table(), inventories)
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

local function row_index(rows)
  local result = {}
  for _, row in ipairs(rows) do
    result[row.from_state] = row
  end
  return result
end

local function matching_successor(row, edge)
  local signature = type(row) == "table" and row.responsibility_signature or nil
  for _, successor in ipairs(type(signature) == "table" and signature.successors or {}) do
    if successor.state == edge.target and successor.output_variant == edge.semantic_variant then
      return successor
    end
  end
  return nil
end

local function expected_bounded_loop_representatives(rows, edges)
  local by_row = row_index(rows)
  local representatives = {}
  for _, edge in ipairs(edges) do
    local row = by_row[edge.row_id]
    local budget = type(row) == "table" and row.budget or nil
    local successor = matching_successor(row, edge)
    local defer = type(row) == "table" and row.defer or nil
    local policy = edge.cas_policy_id and restart_cas_catalog.definition(edge.cas_policy_id) or nil
    local has_row_budget = type(budget) == "table"
      and type(budget.minutes) == "number" and budget.minutes > 0
    local signals = {
      ["self-loop"] = has_row_budget
        and (
          (type(edge.source) == "table"
            and edge.source.state ~= nil
            and edge.source.state == edge.target)
          or (edge.kind == "entry"
            and edge.row_id == edge.target
            and type(policy) == "table"
            and policy.evidence_type == "review_loop_safe_cas_evidence_v1")
        ),
      release = type(defer) == "table"
        and defer.clear_opens_generation == true
        and type(successor) == "table"
        and successor.bump == true,
      timeout = has_row_budget
        and edge.kind == "timeout"
        and type(edge.timeout_evidence_policy_id) == "string"
        and edge.timeout_evidence_policy_id ~= "",
      ["stale-lineage"] = type(policy) == "table"
        and (policy.base == "plain" or policy.base == "versioned" or policy.base == "cyclic"),
    }
    for _, loop_class in ipairs(LOOP_CLASS_ORDER) do
      if signals[loop_class] and representatives[loop_class] == nil then
        representatives[loop_class] = edge
      end
    end
  end
  return representatives
end

local function bounded_loop_key(loop_class, edge_id)
  return loop_class .. "\n" .. edge_id
end

local function bounded_loop_witness_index_without(rows, edges, excluded_loop_class)
  local representatives = expected_bounded_loop_representatives(rows, edges)
  local result = owner_projection.frozen_bounded_loop_witness_index(
    OWNER,
    restart_obligations.bounded_loop_representatives(rows, edges)
  )
  if excluded_loop_class ~= nil then
    local edge = representatives[excluded_loop_class]
    result[bounded_loop_key(excluded_loop_class, edge.id)] = nil
  end
  return result
end

local function index_by_loop_class(entries)
  local result = {}
  for _, entry in ipairs(entries) do
    result[entry.loop_class] = entry
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
  assert_array = assert_array,
  bounded_loop_key = bounded_loop_key,
  bounded_loop_witness_index_without = bounded_loop_witness_index_without,
  canonical_edges = canonical_edges,
  compatible_edge_pairs = compatible_edge_pairs,
  declared_effect_ids = declared_effect_ids,
  edge_pair_key = edge_pair_key,
  edge_witness_index_without = edge_witness_index_without,
  entitlement_witness_index_without = entitlement_witness_index_without,
  expected_bounded_loop_representatives = expected_bounded_loop_representatives,
  family_variant_groups = family_variant_groups,
  family_variant_witness_index_without = family_variant_witness_index_without,
  index_by_edge = index_by_edge,
  index_by_edge_pair = index_by_edge_pair,
  index_by_loop_class = index_by_loop_class,
  is_family_variant_edge = is_family_variant_edge,
  matching_successor = matching_successor,
  pending_witness_index_without = pending_witness_index_without,
  row_index = row_index,
  timeout_witness_index_without = timeout_witness_index_without,
}
end

return M
