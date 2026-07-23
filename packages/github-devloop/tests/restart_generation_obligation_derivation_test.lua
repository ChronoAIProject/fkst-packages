local h = require("tests.devloop_core_helpers")
local owner_projection = require("devloop.restart_owner_pending_projection")
local restart_authority = require("core.restart_authority")
local restart_obligations = require("devloop.restart_obligations")

local OWNER = "github-devloop"
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local cas_witnesses = {
  require("core.restart.issue_reconcile_obligations")[1],
  require("core.restart.timeout_obligations")[1],
}
local t = h.t

local function rows_and_edges()
  local rows = h.core.restart_transition_table()
  return rows, owner_projection.edges(OWNER, rows, inventories)
end

local function index_by(values, field)
  local result = {}
  for _, value in ipairs(values) do result[value[field]] = value end
  return result
end

local function assert_array_equal(actual, expected, context)
  t.eq(type(actual), "table", context .. ": array")
  t.eq(#actual, #expected, context .. ": length")
  for index, value in ipairs(expected) do
    t.eq(actual[index], value, context .. ": item " .. tostring(index))
  end
end

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local copied = {}
  for key, item in pairs(value) do copied[deep_copy(key)] = deep_copy(item) end
  return copied
end

local function canonical(value)
  if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
  local keys = {}
  for key in pairs(value) do table.insert(keys, key) end
  table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
  local parts = {}
  for _, key in ipairs(keys) do
    table.insert(parts, canonical(key) .. "=" .. canonical(value[key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function cas_witness_index()
  local result = {}
  for _, witness in ipairs(cas_witnesses) do result[witness.edge_id] = witness end
  return result
end

local function derive_prior_kinds(rows, edges)
  local edge_witnesses = owner_projection.frozen_edge_witness_index(OWNER, edges)
  local bounded = restart_obligations.bounded_loop_representatives(rows, edges)
  return {
    cas = restart_obligations.derive(edges, cas_witness_index()),
    pending = restart_obligations.derive_pending(edges,
      owner_projection.frozen_pending_witness_index(OWNER, edges)),
    entitlement = restart_obligations.derive_entitlement(edges,
      owner_projection.frozen_entitlement_witness_index(OWNER, edges)),
    timeout = restart_obligations.derive_timeout(edges,
      owner_projection.frozen_timeout_witness_index(OWNER, rows, edges)),
    edge = restart_obligations.derive_edge(edges, edge_witnesses),
    family_variant = restart_obligations.derive_family_variant(edges,
      owner_projection.frozen_family_variant_witness_index(OWNER, edges)),
    edge_pair = restart_obligations.derive_edge_pair(edges, edge_witnesses),
    bounded_loop = restart_obligations.derive_bounded_loop(rows, edges,
      owner_projection.frozen_bounded_loop_witness_index(OWNER, bounded)),
  }
end

local function admission_for(edge)
  local sealed = restart_authority.seal_snapshot({
    owner = OWNER,
    current = { state = edge.source.state, version = nil },
  })
  return restart_authority.decide_transition(sealed, {
    semantic_variant = edge.semantic_variant,
    target = edge.target,
    source_boundary = edge.source.boundary,
    incoming_version = "2026-06-03T01-02-03Z",
    overlay_version = "2026-06-03T01-02-03Z",
  })
end

return {
  test_real_row_generation_declarations_project_onto_typed_edges = function()
    local rows, edges = rows_and_edges()
    local row_by_id = index_by(rows, "from_state")
    local edge_by_id = index_by(edges, "id")
    local bump = edge_by_id["github-devloop/dependency_wait/guard_boundary/blockers_released"]
    local preserve = edge_by_id["github-devloop/thinking/autonomous/consensus-reached"]

    t.eq(bump.generation_epoch.mode, "bump")
    assert_array_equal(bump.generation_epoch.keys,
      row_by_id[bump.target].responsibility_signature.lineage_keys, "bump generation keys")
    t.eq(preserve.generation_epoch.mode, "preserve")
    t.eq(#preserve.generation_epoch.keys, 0)
    for _, edge in ipairs(edges) do
      assert_array_equal(edge.lineage_keys,
        row_by_id[edge.row_id].responsibility_signature.lineage_keys,
        edge.id .. ": lineage keys")
    end
  end,

  test_generation_derivation_is_obligation_only_for_open_or_bump_and_fails_closed_unmapped = function()
    local _, edges = rows_and_edges()
    local witnesses = owner_projection.frozen_generation_witness_index(OWNER, edges)
    local expected_count = 0
    local removed_edge_id = nil
    for _, edge in ipairs(edges) do
      local applicable = edge.generation_epoch.mode == "open"
        or edge.generation_epoch.mode == "bump"
      if applicable then
        expected_count = expected_count + 1
        removed_edge_id = removed_edge_id or edge.id
        t.eq(type(witnesses[edge.id]), "table", edge.id .. ": frozen witness")
      else
        t.eq(witnesses[edge.id], nil, edge.id .. ": preserve has no witness")
      end
    end
    t.eq(expected_count, 3)
    local derived = restart_obligations.derive_generation(edges, witnesses)
    t.eq(#derived.obligations, expected_count)
    t.eq(#derived.unmapped, 0)
    witnesses[removed_edge_id] = nil
    local unmapped = restart_obligations.derive_generation(edges, witnesses)
    t.eq(#unmapped.obligations, expected_count - 1)
    t.eq(#unmapped.unmapped, 1)
    t.eq(unmapped.unmapped[1].edge_id, removed_edge_id)
    t.eq(unmapped.unmapped[1].reason, "missing-frozen-witness")
  end,

  test_generation_fields_are_shadow_inert_to_all_eight_prior_derivations = function()
    local rows, edges = rows_and_edges()
    local legacy_edges = deep_copy(edges)
    for _, edge in ipairs(legacy_edges) do
      edge.generation_epoch = nil
      edge.lineage_keys = nil
    end
    t.eq(canonical(derive_prior_kinds(rows, edges)),
      canonical(derive_prior_kinds(rows, legacy_edges)))
  end,

  test_generation_fields_are_shadow_inert_to_all_canonical_decider_admissions = function()
    local _, edges = rows_and_edges()
    local authority_edges = restart_authority.edges()
    local saved = {}
    for _, edge in ipairs(authority_edges) do
      saved[edge] = {
        generation_epoch = edge.generation_epoch,
        lineage_keys = edge.lineage_keys,
      }
      edge.generation_epoch = nil
      edge.lineage_keys = nil
    end
    local legacy = {}
    for _, edge in ipairs(edges) do legacy[edge.id] = admission_for(edge) end
    for edge, fields in pairs(saved) do
      edge.generation_epoch = fields.generation_epoch
      edge.lineage_keys = fields.lineage_keys
    end
    local projected = {}
    for _, edge in ipairs(edges) do projected[edge.id] = admission_for(edge) end
    t.eq(canonical(projected), canonical(legacy))
  end,
}
