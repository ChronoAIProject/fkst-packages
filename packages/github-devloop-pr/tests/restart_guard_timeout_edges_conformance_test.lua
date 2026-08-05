local fixture = require("tests.restart_edges_conformance_helpers")
local h = fixture.h
local entry_inventory = fixture.entry_inventory
local restart_cas_catalog = fixture.restart_cas_catalog
local restart_edges = fixture.restart_edges
local core = fixture.core
local t = fixture.t
local structural_fields = fixture.structural_fields
local deferred_kinds = fixture.deferred_kinds
local expected_successor_kinds = fixture.expected_successor_kinds
local expected_real_cas_by_id = fixture.expected_real_cas_by_id
local key_set = fixture.key_set
local empty_entitlements = fixture.empty_entitlements
local assert_exact_keys = fixture.assert_exact_keys
local assert_semantic_variant = fixture.assert_semantic_variant
local copy_value = fixture.copy_value
local assert_same_value = fixture.assert_same_value
local assert_valid_cas = fixture.assert_valid_cas
local expected_edges = fixture.expected_edges
local expected_guard_boundary_edges = fixture.expected_guard_boundary_edges
local timeout_policy_by_source = fixture.timeout_policy_by_source
local expected_timeout_edges = fixture.expected_timeout_edges
local assert_edges = fixture.assert_edges
local assert_guard_boundary_edges = fixture.assert_guard_boundary_edges
local assert_timeout_edges = fixture.assert_timeout_edges
local assert_successor_kind_partition = fixture.assert_successor_kind_partition
local tuple_key = fixture.tuple_key
local output_variant_from_id = fixture.output_variant_from_id
local sorted_set_bytes = fixture.sorted_set_bytes
local legacy_union_bytes = fixture.legacy_union_bytes
local extracted_union_bytes = fixture.extracted_union_bytes
local row = fixture.row
local guard_row = fixture.guard_row
local assert_extract_fails = fixture.assert_extract_fails
local assert_guard_extract_fails = fixture.assert_guard_extract_fails
local assert_timeout_extract_fails = fixture.assert_timeout_extract_fails
local row_by_state = fixture.row_by_state

return {
  test_restart_guard_boundary_edges_match_pr_rows_in_authored_order = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local snapshot = copy_value(rows)
    local expected, rows_without_boundaries = expected_guard_boundary_edges(owner, rows)
    local actual = restart_edges.extract_guard_boundary_edges(owner, rows)
    t.eq(#expected, 4)
    assert_guard_boundary_edges(actual, expected, rows_without_boundaries)
    assert_same_value(rows, snapshot)

    local autonomous_ids = {}
    for _, edge in ipairs(restart_edges.extract_autonomous_edges(owner, rows)) do
      autonomous_ids[edge.id] = true
    end
    for _, edge in ipairs(actual) do
      t.eq(autonomous_ids[edge.id], nil)
    end

    local repeated = restart_edges.extract_guard_boundary_edges(owner, rows)
    assert_guard_boundary_edges(repeated, expected, rows_without_boundaries)
    for index, edge in ipairs(actual) do
      t.is_true(edge ~= repeated[index])
      t.is_true(edge.source ~= repeated[index].source)
      t.is_true(edge.provenance ~= repeated[index].provenance)
    end

    local row_without_boundaries = row("autonomous-only", {
      { state = "autonomous-target", output_variant = "autonomous-output", kind = "autonomous" },
    })
    t.eq(#restart_edges.extract_guard_boundary_edges(owner, { row_without_boundaries }), 0)
  end,

  test_restart_timeout_edges_match_pr_rows_and_closed_evidence_policies = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local snapshot = copy_value(rows)
    local expected = expected_timeout_edges(owner, rows)
    local actual = restart_edges.extract_timeout_edges(owner, rows)

    t.eq(#expected, 2)
    assert_timeout_edges(actual, expected)
    t.eq(actual[1].id, owner .. "/merge-ready/timeout/merge_gate/watchdog_reconcile_terminal")
    t.eq(actual[1].timeout_evidence_policy_id, "timeout.state_entry_legacy_v1")
    t.eq(actual[2].id, owner .. "/reviewing/timeout/watchdog_reconcile_terminal")
    t.eq(actual[2].timeout_evidence_policy_id, "timeout.heartbeat_legacy_v1")
    assert_same_value(rows, snapshot)

    local repeated = restart_edges.extract_timeout_edges(owner, rows)
    assert_timeout_edges(repeated, expected)
    for index, edge in ipairs(actual) do
      t.is_true(edge ~= repeated[index])
      t.is_true(edge.source ~= repeated[index].source)
      t.is_true(edge.provenance ~= repeated[index].provenance)
    end
  end,

  test_restart_guard_boundary_edges_do_not_read_to_states_sort_or_leak_autonomous = function()
    local synthetic = setmetatable({
      from_state = "authored-order",
      responsibility_signature = {
        successors = {
          { state = "autonomous-target", output_variant = "autonomous-only", kind = "autonomous" },
        },
      },
      guard_boundaries = {
        {
          name = "z-boundary",
          successors = {
            { state = "z-target", output_variant = "z-first",
              transition_effect_entitlements = empty_entitlements("pr-owner/authored-order/guard_boundary/z-boundary/z-first") },
            { state = "a-target", output_variant = "a-second",
              transition_effect_entitlements = empty_entitlements("pr-owner/authored-order/guard_boundary/z-boundary/a-second") },
          },
        },
        {
          name = "a-boundary",
          successors = {
            { state = "m-target", output_variant = "m-third",
              transition_effect_entitlements = empty_entitlements("pr-owner/authored-order/guard_boundary/a-boundary/m-third") },
          },
        },
      },
    }, {
      __index = function(_, key)
        if key == "to_states" then
          error("to_states must not be read")
        end
        return nil
      end,
    })
    local expected, rows_without_boundaries = expected_guard_boundary_edges("pr-owner", { synthetic })
    local edges = restart_edges.extract_guard_boundary_edges("pr-owner", { synthetic })
    assert_guard_boundary_edges(edges, expected, rows_without_boundaries)
    t.eq(#edges, 3)
    t.eq(edges[1].id, "pr-owner/authored-order/guard_boundary/z-boundary/z-first")
    t.eq(edges[1].source.boundary, "z-boundary")
    t.eq(edges[2].id, "pr-owner/authored-order/guard_boundary/z-boundary/a-second")
    t.eq(edges[2].source.boundary, "z-boundary")
    t.eq(edges[3].id, "pr-owner/authored-order/guard_boundary/a-boundary/m-third")
    t.eq(edges[3].source.boundary, "a-boundary")
  end,

  test_restart_edges_partition_merge_ready_guard_field_successors = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local merge_ready = row_by_state(rows, "merge-ready")
    local guard = merge_ready.guard_boundaries[1]
    t.eq(guard.kind, "guard_table")
    t.eq(#guard.successors, 4)
    local guard_ids = {}
    for _, edge in ipairs(restart_edges.extract_guard_boundary_edges(owner, rows)) do
      guard_ids[edge.id] = true
    end
    local timeout_ids = {}
    for _, edge in ipairs(restart_edges.extract_timeout_edges(owner, rows)) do
      timeout_ids[edge.id] = true
    end
    for _, successor in ipairs(guard.successors) do
      local guard_id = owner .. "/merge-ready/guard_boundary/merge_gate/" .. successor.output_variant
      local timeout_id = owner .. "/merge-ready/timeout/merge_gate/" .. successor.output_variant
      if successor.output_variant == "watchdog_reconcile_terminal" then
        t.eq(successor.kind, "timeout")
        t.eq(guard_ids[guard_id], nil)
        t.eq(timeout_ids[timeout_id], true)
      else
        t.eq(successor.kind, nil)
        t.eq(guard_ids[guard_id], true)
        t.eq(timeout_ids[timeout_id], nil)
      end
    end
  end,

}
