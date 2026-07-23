local h = require("tests.devloop_core_helpers")
local owner_projection = require("devloop.restart_owner_pending_projection")
local restart_obligations = require("devloop.restart_obligations")

local OWNER = "github-devloop-pr"
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
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

return {
  test_real_row_generation_declarations_project_onto_typed_edges = function()
    local rows, edges = rows_and_edges()
    local row_by_id = index_by(rows, "from_state")
    local edge_by_id = index_by(edges, "id")
    local open = edge_by_id["github-devloop-pr/reviewing/entry/first_seen_pr"]
    local bump = edge_by_id["github-devloop-pr/reviewing/autonomous/changes_requested"]
    local preserve = edge_by_id["github-devloop-pr/reviewing/autonomous/approved"]

    t.eq(open.generation_epoch.mode, "open")
    assert_array_equal(open.generation_epoch.keys,
      row_by_id[open.target].responsibility_signature.lineage_keys, "open generation keys")
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

    t.eq(expected_count, 17)
    local derived = restart_obligations.derive_generation(edges, witnesses)
    t.eq(#derived.obligations, expected_count)
    t.eq(#derived.unmapped, 0)
    for _, obligation in ipairs(derived.obligations) do
      t.eq(obligation.case_kind, "generation")
      t.eq(obligation.obligation_id, obligation.edge_id .. "/generation")
    end

    witnesses[removed_edge_id] = nil
    local unmapped = restart_obligations.derive_generation(edges, witnesses)
    t.eq(#unmapped.obligations, expected_count - 1)
    t.eq(#unmapped.unmapped, 1)
    t.eq(unmapped.unmapped[1].edge_id, removed_edge_id)
    t.eq(unmapped.unmapped[1].reason, "missing-frozen-witness")
  end,
}
