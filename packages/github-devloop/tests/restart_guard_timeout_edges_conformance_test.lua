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
  test_restart_guard_boundary_edges_match_issue_rows_in_authored_order = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local snapshot = copy_value(rows)
    local expected, rows_without_boundaries = expected_guard_boundary_edges(owner, rows)
    local actual = restart_edges.extract_guard_boundary_edges(owner, rows)
    t.eq(#expected, 7)
    assert_guard_boundary_edges(actual, expected, rows_without_boundaries)
    assert_same_value(rows, snapshot)

    local autonomous_only = row("autonomous-only", {
      { state = "autonomous-target", output_variant = "autonomous-output", kind = "autonomous" },
    })
    t.eq(#restart_edges.extract_guard_boundary_edges(owner, { autonomous_only }), 0)
  end,

  test_restart_timeout_edges_match_issue_rows_and_closed_evidence_policy = function()
    local owner = core.restart_package_name
    local rows = core.restart_transition_table()
    local snapshot = copy_value(rows)
    local expected = expected_timeout_edges(owner, rows)
    local actual = restart_edges.extract_timeout_edges(owner, rows)

    t.eq(#expected, 1)
    assert_timeout_edges(actual, expected)
    t.eq(actual[1].id, owner .. "/ready/timeout/actionable_kickoff_timeout")
    t.eq(actual[1].timeout_evidence_policy_id, "timeout.state_entry_legacy_v1")
    assert_same_value(rows, snapshot)

    local repeated = restart_edges.extract_timeout_edges(owner, rows)
    assert_timeout_edges(repeated, expected)
    t.is_true(actual[1] ~= repeated[1])
    t.is_true(actual[1].source ~= repeated[1].source)
    t.is_true(actual[1].provenance ~= repeated[1].provenance)
  end,

  test_restart_edges_do_not_read_to_states_or_override_explicit_kinds = function()
    local synthetic = setmetatable({
      from_state = "authored-order",
      responsibility_signature = {
        successors = {
          { state = "z-target", output_variant = "z-first", kind = "timeout",
            transition_effect_entitlements = empty_entitlements("issue-owner/authored-order/timeout/z-first") },
          { state = "a-target", output_variant = "a-second", kind = "guard_boundary",
            transition_effect_entitlements = empty_entitlements("issue-owner/authored-order/guard_boundary/a-second") },
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
    local edges = restart_edges.extract_autonomous_edges("issue-owner", { synthetic })
    t.eq(#edges, 0)
    local timeout_edges = restart_edges.extract_timeout_edges("issue-owner", {
      setmetatable({
        from_state = synthetic.from_state,
        actionable_epoch = { source = "state_entry:v1" },
        responsibility_signature = {
          successors = { synthetic.responsibility_signature.successors[1] },
        },
      }, getmetatable(synthetic)),
    })
    t.eq(#timeout_edges, 1)
    t.eq(timeout_edges[1].id, "issue-owner/authored-order/timeout/z-first")
    local guard_edges = restart_edges.extract_guard_boundary_edges("issue-owner", { synthetic })
    t.eq(#guard_edges, 1)
    t.eq(guard_edges[1].id, "issue-owner/authored-order/guard_boundary/a-second")
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
              transition_effect_entitlements = empty_entitlements("issue-owner/authored-order/guard_boundary/z-boundary/z-first") },
            { state = "a-target", output_variant = "a-second",
              transition_effect_entitlements = empty_entitlements("issue-owner/authored-order/guard_boundary/z-boundary/a-second") },
          },
        },
        {
          name = "a-boundary",
          successors = {
            { state = "m-target", output_variant = "m-third",
              transition_effect_entitlements = empty_entitlements("issue-owner/authored-order/guard_boundary/a-boundary/m-third") },
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
    local expected, rows_without_boundaries = expected_guard_boundary_edges("issue-owner", { synthetic })
    local edges = restart_edges.extract_guard_boundary_edges("issue-owner", { synthetic })
    assert_guard_boundary_edges(edges, expected, rows_without_boundaries)
    t.eq(#edges, 3)
    t.eq(edges[1].id, "issue-owner/authored-order/guard_boundary/z-boundary/z-first")
    t.eq(edges[1].source.boundary, "z-boundary")
    t.eq(edges[2].id, "issue-owner/authored-order/guard_boundary/z-boundary/a-second")
    t.eq(edges[2].source.boundary, "z-boundary")
    t.eq(edges[3].id, "issue-owner/authored-order/guard_boundary/a-boundary/m-third")
    t.eq(edges[3].source.boundary, "a-boundary")

    local repeated = restart_edges.extract_guard_boundary_edges("issue-owner", { synthetic })
    assert_guard_boundary_edges(repeated, expected, rows_without_boundaries)
    for index, edge in ipairs(edges) do
      t.is_true(edge ~= repeated[index])
      t.is_true(edge.source ~= repeated[index].source)
      t.is_true(edge.provenance ~= repeated[index].provenance)
    end
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
