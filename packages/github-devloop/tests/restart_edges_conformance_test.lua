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
local expected_guard_boundary_cas_by_id = fixture.expected_guard_boundary_cas_by_id
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
  test_restart_edges_schema_is_explicit_about_extracted_and_deferred_kinds = function()
    assert_exact_keys(restart_edges, {
      extract_autonomous_edges = true,
      extract_canonicalization_edges = true,
      extract_entry_edges = true,
      extract_guard_boundary_edges = true,
      extract_operator_reentry_edges = true,
      extract_timeout_edges = true,
      project_generation_fields = true,
      schema = true,
    })
    local schema = restart_edges.schema()
    assert_exact_keys(schema, {
      structural_fields = true,
      extracted_kinds = true,
      deferred_kinds = true,
    })
    t.eq(#schema.structural_fields, #structural_fields)
    for index, field in ipairs(structural_fields) do
      t.eq(schema.structural_fields[index], field)
    end
    assert_exact_keys(schema.extracted_kinds, {
      autonomous = true,
      canonicalization = true,
      entry = true,
      guard_boundary = true,
      operator_reentry = true,
      timeout = true,
    })
    t.eq(schema.extracted_kinds.autonomous, true)
    t.eq(schema.extracted_kinds.canonicalization, true)
    t.eq(schema.extracted_kinds.entry, true)
    t.eq(schema.extracted_kinds.guard_boundary, true)
    t.eq(schema.extracted_kinds.operator_reentry, true)
    t.eq(schema.extracted_kinds.timeout, true)
    t.eq(#schema.deferred_kinds, #deferred_kinds)
    for index, kind in ipairs(deferred_kinds) do
      t.eq(schema.deferred_kinds[index], kind)
    end
  end,

  test_restart_edges_match_issue_rows_in_registry_and_authored_successor_order = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local snapshot = copy_value(rows)
    assert_successor_kind_partition(rows)
    local expected, empty_rows = expected_edges(owner, rows)
    for _, edge in ipairs(expected) do
      if edge.id == owner .. "/thinking/autonomous/consensus-reached" then
        edge.pending_order = { participates = true, predecessor_state = "thinking" }
      end
      if edge.id == owner .. "/thinking/autonomous/consensus-reached-dependency-held" then
        edge.cas_policy_id = "cas.legacy_consensus_result_v1"
        edge.cas_variant = "thinking_to_dependency_wait"
      end
    end
    for _, edge in ipairs(expected) do
      local expected_cas = expected_real_cas_by_id[edge.id]
      if expected_cas ~= nil then
        edge.cas_policy_id = expected_cas.cas_policy_id
        edge.cas_variant = expected_cas.cas_variant
      end
    end
    local actual = restart_edges.extract_autonomous_edges(owner, rows)
    t.eq(#actual, 7)
    assert_edges(actual, expected, empty_rows)
    assert_same_value(rows, snapshot)

    local repeated = restart_edges.extract_autonomous_edges(owner, rows)
    assert_edges(repeated, expected, empty_rows)
    for index, edge in ipairs(actual) do
      t.is_true(edge ~= repeated[index])
      t.is_true(edge.source ~= repeated[index].source)
      t.is_true(edge.provenance ~= repeated[index].provenance)
    end

    -- Inventory-authored canonicalization edges have their own production-observation conformance.
    -- This successor conformance remains scoped to responsibility_signature.successors.
  end,

  test_thinking_dependency_wait_edge_cas_metadata_references_declared_policy = function()
    local owner = core.restart_package_name
    local edge_id = owner .. "/thinking/autonomous/consensus-reached-dependency-held"
    local edge
    for _, candidate in ipairs(restart_edges.extract_autonomous_edges(owner, core.restart_transition_table())) do
      if candidate.id == edge_id then
        edge = candidate
      end
    end

    t.is_true(edge ~= nil)
    t.eq(edge.cas_policy_id, "cas.legacy_consensus_result_v1")
    t.eq(edge.cas_variant, "thinking_to_dependency_wait")
    assert_valid_cas(edge)
  end,

  test_autonomous_cas_metadata_is_optional_copied_and_fail_closed = function()
    local valid = row("from", {
      {
        state = "with-cas",
        output_variant = "with-cas",
        kind = "autonomous",
        cas_policy_id = "cas.synthetic_v1",
        cas_variant = "synthetic_variant",
        transition_effect_entitlements = empty_entitlements("owner/from/autonomous/with-cas"),
      },
      { state = "without-cas", output_variant = "without-cas", kind = "autonomous",
        transition_effect_entitlements = empty_entitlements("owner/from/autonomous/without-cas") },
    })
    local edges = restart_edges.extract_autonomous_edges("owner", { valid })
    t.eq(#edges, 2)
    assert_exact_keys(edges[1], {
      id = true,
      owner = true,
      row_id = true,
      kind = true,
      source = true,
      target = true,
      semantic_variant = true,
      cas_policy_id = true,
      cas_variant = true,
      transition_effect_entitlements = true,
      provenance = true,
    })
    t.eq(edges[1].cas_policy_id, "cas.synthetic_v1")
    t.eq(edges[1].cas_variant, "synthetic_variant")
    local edge_keys = key_set(structural_fields)
    edge_keys.semantic_variant = true
    edge_keys.transition_effect_entitlements = true
    assert_exact_keys(edges[2], edge_keys)
    t.eq(edges[2].cas_policy_id, nil)
    t.eq(edges[2].cas_variant, nil)

    assert_extract_fails("owner", {
      row("from", { { state = "to", output_variant = "done", kind = "autonomous", cas_policy_id = "" } }),
    })
    assert_extract_fails("owner", {
      row("from", { { state = "to", output_variant = "done", kind = "autonomous", cas_policy_id = 1 } }),
    })
    assert_extract_fails("owner", {
      row("from", { { state = "to", output_variant = "done", kind = "autonomous", cas_variant = "" } }),
    })
    assert_extract_fails("owner", {
      row("from", { { state = "to", output_variant = "done", kind = "autonomous", cas_variant = false } }),
    })
  end,

  test_restart_edge_kind_partition_preserves_the_legacy_issue_union_byte_for_byte = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local before = legacy_union_bytes(owner, rows, entry_inventory)
    local after = extracted_union_bytes(owner, rows, entry_inventory)
    t.eq(after, before)
  end,

  test_thinking_same_target_autonomous_and_receiver_activation_edges_coexist = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local autonomous_by_id = {}
    for _, edge in ipairs(restart_edges.extract_autonomous_edges(owner, rows)) do
      autonomous_by_id[edge.id] = edge
    end
    local entry_by_id = {}
    for _, edge in ipairs(restart_edges.extract_entry_edges(owner, entry_inventory, rows)) do
      entry_by_id[edge.id] = edge
    end

    local stalled = autonomous_by_id[owner .. "/thinking/autonomous/consensus-stalled"]
    local reconcile = entry_by_id[owner .. "/thinking/entry/issue_reconcile_true_stall"]
    t.is_true(stalled ~= nil)
    t.is_true(reconcile ~= nil)
    t.eq(stalled.target, "blocked")
    t.eq(reconcile.target, "blocked")
  end,

  test_restart_edges_exclude_blocked_operator_reentry = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local blocked = row_by_state(rows, "blocked")
    t.eq(blocked.operator_reentry.not_autonomous_successor, true)
    t.eq(blocked.responsibility_signature.operator_reentry.not_autonomous_successor, true)
    t.eq(#blocked.responsibility_signature.successors, 0)
    for _, edge in ipairs(restart_edges.extract_autonomous_edges(owner, rows)) do
      t.is_true(edge.row_id ~= "blocked")
    end
  end,
}
