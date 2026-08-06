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

  test_restart_edges_match_pr_rows_in_registry_and_authored_successor_order = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local snapshot = copy_value(rows)
    assert_successor_kind_partition(rows)
    local expected, empty_rows = expected_edges(owner, rows)
    local actual = restart_edges.extract_autonomous_edges(owner, rows)
    t.eq(#actual, 15)
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

  test_restart_edge_kind_partition_preserves_the_legacy_pr_union_byte_for_byte = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local entries = restart_edges.extract_entry_edges(owner, entry_inventory, rows)
    local entry_ids = {}
    local entry_counts = {}
    for _, edge in ipairs(entries) do
      entry_ids[edge.id] = true
      entry_counts[edge.row_id] = (entry_counts[edge.row_id] or 0) + 1
    end
    t.eq(#entries, 17)
    t.eq(entry_counts.reviewing, 5)
    t.eq(entry_counts.fixing, 3)
    t.eq(entry_counts["merge-ready"], 3)
    t.eq(entry_counts.merging, 3)
    t.eq(entry_counts["pr-open"], 2)
    t.eq(entry_counts["review-meta"], 1)
    t.eq(entry_ids[owner .. "/merge-ready/entry/handoff_to_merge_gate"], true)
    for _, state in ipairs({ "fixing", "merge-ready", "merging" }) do
      t.eq(entry_ids[owner .. "/" .. state .. "/entry/review_reject_to_blocked"], true)
      t.eq(entry_ids[owner .. "/" .. state .. "/entry/bounded_fix_to_blocked"], true)
    end
    t.eq(entry_ids[owner .. "/reviewing/entry/review_convergence_round"], true)
    t.eq(entry_ids[owner .. "/reviewing/entry/review_reject_to_blocked"], true)
    t.eq(entry_ids[owner .. "/reviewing/entry/review_reconcile_true_stall"], true)
    local before = legacy_union_bytes(owner, rows, entry_inventory)
    local after = extracted_union_bytes(owner, rows, entry_inventory)
    t.eq(after, before)
  end,

  test_restart_edges_do_not_read_to_states_or_override_explicit_kinds = function()
    local synthetic = setmetatable({
      from_state = "authored-order",
      responsibility_signature = {
        successors = {
          { state = "z-target", output_variant = "z-first", kind = "timeout",
            transition_effect_entitlements = empty_entitlements("pr-owner/authored-order/timeout/z-first") },
          { state = "a-target", output_variant = "a-second", kind = "guard_boundary",
            transition_effect_entitlements = empty_entitlements("pr-owner/authored-order/guard_boundary/a-second") },
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
    local edges = restart_edges.extract_autonomous_edges("pr-owner", { synthetic })
    t.eq(#edges, 0)
    local timeout_edges = restart_edges.extract_timeout_edges("pr-owner", {
      setmetatable({
        from_state = synthetic.from_state,
        actionable_epoch = { source = "state_entry:v1" },
        responsibility_signature = {
          successors = { synthetic.responsibility_signature.successors[1] },
        },
      }, getmetatable(synthetic)),
    })
    t.eq(#timeout_edges, 1)
    t.eq(timeout_edges[1].id, "pr-owner/authored-order/timeout/z-first")
    local guard_edges = restart_edges.extract_guard_boundary_edges("pr-owner", { synthetic })
    t.eq(#guard_edges, 1)
    t.eq(guard_edges[1].id, "pr-owner/authored-order/guard_boundary/a-second")
  end,

  test_restart_edges_fail_closed_on_invalid_authored_inputs = function()
    local valid = row("from", { { state = "to", output_variant = "done", kind = "autonomous" } })
    assert_extract_fails("", { valid })
    assert_extract_fails("owner", { row(nil, { { state = "to", output_variant = "done", kind = "autonomous" } }) })
    assert_extract_fails("owner", { row("", { { state = "to", output_variant = "done", kind = "autonomous" } }) })
    assert_extract_fails("owner", { { from_state = "from", responsibility_signature = {} } })
    assert_extract_fails("owner", { row("from", { { output_variant = "done", kind = "autonomous" } }) })
    assert_extract_fails("owner", { row("from", { { state = "", output_variant = "done", kind = "autonomous" } }) })
    assert_extract_fails("owner", { row("from", { { state = "to", kind = "autonomous" } }) })
    assert_extract_fails("owner", { row("from", { { state = "to", output_variant = "", kind = "autonomous" } }) })
    assert_extract_fails("owner", { row("from", { { state = "to", output_variant = "done" } }) })
    assert_extract_fails("owner", { row("from", { { state = "to", output_variant = "done", kind = "other" } }) })
    assert_extract_fails("owner", {
      row("from", {
        { state = "one", output_variant = "same", kind = "autonomous" },
        { state = "two", output_variant = "same", kind = "autonomous" },
      }),
    })

    assert_timeout_extract_fails("", { valid })
    assert_timeout_extract_fails("owner", {
      row("from", { { state = "to", output_variant = "done", kind = "timeout" } }),
    })
    assert_timeout_extract_fails("owner", {
      {
        from_state = "from",
        actionable_epoch = { source = "unknown:v1" },
        responsibility_signature = {
          successors = { { state = "to", output_variant = "done", kind = "timeout" } },
        },
      },
    })

    local valid_guard = guard_row("from", {
      {
        name = "boundary",
        successors = { { state = "to", output_variant = "done" } },
      },
    })
    assert_guard_extract_fails("", { valid_guard })
    assert_guard_extract_fails("owner", { guard_row(nil, {}) })
    assert_guard_extract_fails("owner", { guard_row("", {}) })
    assert_guard_extract_fails("owner", { guard_row("from", { { successors = {} } }) })
    assert_guard_extract_fails("owner", { guard_row("from", { { name = "", successors = {} } }) })
    assert_guard_extract_fails("owner", { guard_row("from", { { name = "boundary" } }) })
    assert_guard_extract_fails("owner", {
      guard_row("from", { { name = "boundary", successors = { { output_variant = "done" } } } }),
    })
    assert_guard_extract_fails("owner", {
      guard_row("from", { { name = "boundary", successors = { { state = "", output_variant = "done" } } } }),
    })
    assert_guard_extract_fails("owner", {
      guard_row("from", { { name = "boundary", successors = { { state = "to" } } } }),
    })
    assert_guard_extract_fails("owner", {
      guard_row("from", { { name = "boundary", successors = { { state = "to", output_variant = "" } } } }),
    })
    assert_guard_extract_fails("owner", {
      guard_row("from", {
        {
          name = "boundary",
          successors = {
            { state = "one", output_variant = "same" },
            { state = "two", output_variant = "same" },
          },
        },
      }),
    })
  end,
}
