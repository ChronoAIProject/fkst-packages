local h = require("tests.devloop_core_helpers")
local entry_inventory = require("core.restart.entry_inventory")
local restart_cas_catalog = require("devloop.restart_cas_catalog")
local restart_edges = require("devloop.restart_edges")

local core = h.core
local t = h.t

local structural_fields = {
  "id",
  "owner",
  "row_id",
  "kind",
  "source",
  "target",
  "provenance",
}

local deferred_kinds = {}

local expected_successor_kinds = {
  ["awaiting-pr/awaiting_pr_to_merged"] = "guard_boundary",
  ["awaiting-pr/awaiting_pr_to_ready"] = "guard_boundary",
  ["awaiting-pr/awaiting_pr_to_blocked"] = "guard_boundary",
  ["dependency_wait/blockers_still_open"] = "guard_boundary",
  ["dependency_wait/blockers_released"] = "guard_boundary",
  ["dependency_wait/dependency_resolver_stale"] = "guard_boundary",
  ["implementing/revision_published"] = "autonomous",
  ["implementing/implementation_refused"] = "autonomous",
  ["implementing/revision_failed"] = "autonomous",
  ["ready/blocker_reappeared"] = "guard_boundary",
  ["ready/actionable_kickoff_timeout"] = "timeout",
  ["thinking/consensus-reached"] = "autonomous",
  ["thinking/consensus-reached-dependency-held"] = "autonomous",
  ["thinking/premise-refuted"] = "autonomous",
  ["thinking/consensus-stalled"] = "autonomous",
}

local expected_real_cas_by_id = {
  ["github-devloop/implementing/autonomous/revision_published"] = {
    cas_policy_id = "cas.legacy_awaiting_pr_v1",
    cas_variant = "implementing_to_awaiting_pr",
  },
  ["github-devloop/thinking/autonomous/consensus-reached"] = {
    cas_policy_id = "cas.legacy_consensus_result_v1",
    cas_variant = "thinking_to_ready",
  },
  ["github-devloop/thinking/autonomous/premise-refuted"] = {
    cas_policy_id = "cas.legacy_consensus_result_v1",
    cas_variant = "thinking_to_declined",
  },
  ["github-devloop/thinking/autonomous/consensus-stalled"] = {
    cas_policy_id = "cas.legacy_loop_plain_v1",
    cas_variant = "thinking_to_blocked",
  },
  ["github-devloop/ready/timeout/actionable_kickoff_timeout"] = { cas_policy_id = "cas.legacy_timeout_reconcile_v1", cas_variant = "ready_to_blocked" },
}

local expected_guard_boundary_cas_by_id = {
  ["github-devloop/awaiting-pr/guard_boundary/awaiting_pr_to_merged"] =
    { cas_policy_id = "cas.legacy_awaiting_pr_v1", cas_variant = "awaiting_pr_to_merged" },
  ["github-devloop/awaiting-pr/guard_boundary/awaiting_pr_to_ready"] =
    { cas_policy_id = "cas.legacy_awaiting_pr_v1", cas_variant = "awaiting_pr_to_ready" },
  ["github-devloop/awaiting-pr/guard_boundary/awaiting_pr_to_blocked"] =
    { cas_policy_id = "cas.legacy_awaiting_pr_v1", cas_variant = "awaiting_pr_to_blocked" },
}

local function key_set(keys)
  local out = {}
  for _, key in ipairs(keys) do
    out[key] = true
  end
  return out
end

local function empty_entitlements(id)
  return {
    apply = { id = id .. "/apply", effect_ids = {} },
    idempotent = { id = id .. "/idempotent", effect_ids = {} },
  }
end

local function assert_exact_keys(value, expected)
  local count = 0
  for key in pairs(value) do
    count = count + 1
    t.eq(expected[key], true)
  end
  local expected_count = 0
  for _ in pairs(expected) do
    expected_count = expected_count + 1
  end
  t.eq(count, expected_count)
end

local function assert_semantic_variant(edge)
  t.eq(type(edge.semantic_variant), "string")
  t.is_true(edge.semantic_variant ~= "")
  t.eq(edge.semantic_variant:find("/", 1, true), nil)
  t.eq(edge.semantic_variant, tostring(edge.id):match("/([^/]+)$"))
end

local function copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, nested in pairs(value) do
    out[key] = copy_value(nested)
  end
  return out
end

local function assert_same_value(actual, expected)
  if type(expected) ~= "table" then
    t.eq(actual, expected)
    return
  end
  t.eq(type(actual), "table")
  local actual_count = 0
  for _ in pairs(actual) do
    actual_count = actual_count + 1
  end
  local expected_count = 0
  for key, nested in pairs(expected) do
    expected_count = expected_count + 1
    assert_same_value(actual[key], nested)
  end
  t.eq(actual_count, expected_count)
end

local function assert_valid_cas(edge)
  if edge.cas_policy_id == nil then
    return
  end
  local definition = restart_cas_catalog.definition(edge.cas_policy_id)
  t.is_true(definition ~= nil)
  if edge.cas_variant ~= nil then
    t.is_true(definition.variants ~= nil)
    t.is_true(definition.variants[edge.cas_variant] ~= nil)
  end
end

local function expected_edges(owner, rows)
  local expected = {}
  local empty_rows = {}
  for _, row in ipairs(rows) do
    local successors = row.responsibility_signature.successors
    local row_has_edge = false
    for _, successor in ipairs(successors) do
      if successor.kind == "autonomous" then
        row_has_edge = true
        table.insert(expected, {
          id = owner .. "/" .. row.from_state .. "/autonomous/" .. successor.output_variant,
          owner = owner,
          row_id = row.from_state,
          kind = "autonomous",
          source = { state = row.from_state, boundary = nil },
          target = successor.state,
          semantic_variant = successor.output_variant,
          transition_effect_entitlements = copy_value(successor.transition_effect_entitlements),
          pending_order = copy_value(successor.pending_order),
          provenance = {
            owner = owner,
            row = row.from_state,
            field = "responsibility_signature.successors",
          },
        })
      end
    end
    if not row_has_edge then
      table.insert(empty_rows, row.from_state)
    end
  end
  return expected, empty_rows
end

local function expected_guard_boundary_edges(owner, rows)
  local expected = {}
  local rows_without_boundaries = {}
  for _, row in ipairs(rows) do
    local row_has_edge = false
    local signature = row.responsibility_signature
    for _, successor in ipairs(type(signature) == "table" and signature.successors or {}) do
      if successor.kind == "guard_boundary" then
        row_has_edge = true
        table.insert(expected, {
          id = owner .. "/" .. row.from_state .. "/guard_boundary/" .. successor.output_variant,
          owner = owner,
          row_id = row.from_state,
          kind = "guard_boundary",
          source = { state = row.from_state, boundary = nil },
          target = successor.state,
          semantic_variant = successor.output_variant,
          transition_effect_entitlements = copy_value(successor.transition_effect_entitlements),
          pending_order = copy_value(successor.pending_order),
          provenance = {
            owner = owner,
            row = row.from_state,
            field = "responsibility_signature.successors",
          },
        })
        local expected_cas = expected_guard_boundary_cas_by_id[expected[#expected].id]
        if expected_cas ~= nil then
          expected[#expected].cas_policy_id = expected_cas.cas_policy_id
          expected[#expected].cas_variant = expected_cas.cas_variant
        end
      end
    end
    if row.guard_boundaries ~= nil then
      for _, guard_boundary in ipairs(row.guard_boundaries) do
        for _, successor in ipairs(guard_boundary.successors) do
          if successor.kind ~= "timeout" then
            row_has_edge = true
            table.insert(expected, {
              id = owner .. "/" .. row.from_state .. "/guard_boundary/" .. guard_boundary.name .. "/" .. successor.output_variant,
              owner = owner,
              row_id = row.from_state,
              kind = "guard_boundary",
              source = { state = row.from_state, boundary = guard_boundary.name },
              target = successor.state,
              semantic_variant = successor.output_variant,
              transition_effect_entitlements = copy_value(successor.transition_effect_entitlements),
              pending_order = copy_value(successor.pending_order),
              provenance = {
                owner = owner,
                row = row.from_state,
                field = "guard_boundaries",
              },
            })
          end
        end
      end
    end
    if not row_has_edge then
      table.insert(rows_without_boundaries, row.from_state)
    end
  end
  return expected, rows_without_boundaries
end

local timeout_policy_by_source = {
  ["state_entry:v1"] = "timeout.state_entry_legacy_v1",
  ["codex_run:v1"] = "timeout.codex_run_legacy_v1",
  ["live_defer_heartbeat:v1"] = "timeout.heartbeat_legacy_v1",
  ["live_defer_epoch:v1"] = "timeout.durable_clear_legacy_v1",
  ["child_workflow_wait:v1"] = "timeout.child_workflow_legacy_v1",
}

local function expected_timeout_edges(owner, rows)
  local expected = {}
  for _, row in ipairs(rows) do
    local policy_id = timeout_policy_by_source[row.actionable_epoch and row.actionable_epoch.source]
    for _, successor in ipairs(row.responsibility_signature.successors) do
      if successor.kind == "timeout" then
        local edge_id = owner .. "/" .. row.from_state .. "/timeout/" .. successor.output_variant; local expected_cas = expected_real_cas_by_id[edge_id]
        table.insert(expected, {
          id = edge_id,
          owner = owner,
          row_id = row.from_state,
          kind = "timeout",
          source = { state = row.from_state, boundary = nil },
          target = successor.state,
          semantic_variant = successor.output_variant,
          transition_effect_entitlements = copy_value(successor.transition_effect_entitlements),
          pending_order = copy_value(successor.pending_order),
          timeout_evidence_policy_id = policy_id,
          cas_policy_id = expected_cas and expected_cas.cas_policy_id or nil, cas_variant = expected_cas and expected_cas.cas_variant or nil,
          provenance = {
            owner = owner,
            row = row.from_state,
            field = "responsibility_signature.successors",
          },
        })
      end
    end
    for _, guard_boundary in ipairs(row.guard_boundaries or {}) do
      for _, successor in ipairs(guard_boundary.successors) do
        if successor.kind == "timeout" then
          table.insert(expected, {
            id = owner .. "/" .. row.from_state .. "/timeout/" .. guard_boundary.name .. "/" .. successor.output_variant,
            owner = owner,
            row_id = row.from_state,
            kind = "timeout",
            source = { state = row.from_state, boundary = guard_boundary.name },
            target = successor.state,
            semantic_variant = successor.output_variant,
            transition_effect_entitlements = copy_value(successor.transition_effect_entitlements),
            pending_order = copy_value(successor.pending_order),
            timeout_evidence_policy_id = policy_id,
            provenance = {
              owner = owner,
              row = row.from_state,
              field = "guard_boundaries",
            },
          })
        end
      end
    end
  end
  return expected
end

local function assert_edges(actual, expected, empty_rows)
  t.eq(#actual, #expected)
  local seen_ids = {}
  local seen_edges = {}
  local seen_sources = {}
  local seen_provenance = {}
  local counts_by_row = {}
  for index, expected_edge in ipairs(expected) do
    local edge = actual[index]
    local edge_keys = key_set(structural_fields)
    edge_keys.semantic_variant = true
    if expected_edge.cas_policy_id ~= nil then
      edge_keys.cas_policy_id = true
    end
    if expected_edge.cas_variant ~= nil then
      edge_keys.cas_variant = true
    end
    if expected_edge.pending_order ~= nil then
      edge_keys.pending_order = true
    end
    if expected_edge.transition_effect_entitlements ~= nil then
      edge_keys.transition_effect_entitlements = true
    end
    assert_exact_keys(edge, edge_keys)
    assert_exact_keys(edge.source, { state = true })
    assert_exact_keys(edge.provenance, { owner = true, row = true, field = true })
    t.eq(edge.id, expected_edge.id)
    t.eq(edge.owner, expected_edge.owner)
    t.eq(edge.row_id, expected_edge.row_id)
    t.eq(edge.kind, expected_edge.kind)
    t.eq(edge.source.state, expected_edge.source.state)
    t.eq(edge.source.boundary, nil)
    t.eq(edge.target, expected_edge.target)
    t.eq(edge.semantic_variant, expected_edge.semantic_variant)
    assert_semantic_variant(edge)
    t.eq(edge.cas_policy_id, expected_edge.cas_policy_id)
    t.eq(edge.cas_variant, expected_edge.cas_variant)
    assert_same_value(edge.pending_order, expected_edge.pending_order)
    assert_same_value(edge.transition_effect_entitlements, expected_edge.transition_effect_entitlements)
    assert_valid_cas(edge)
    t.eq(edge.provenance.owner, expected_edge.provenance.owner)
    t.eq(edge.provenance.row, expected_edge.provenance.row)
    t.eq(edge.provenance.field, expected_edge.provenance.field)
    t.eq(seen_ids[edge.id], nil)
    t.eq(seen_edges[edge], nil)
    t.eq(seen_sources[edge.source], nil)
    t.eq(seen_provenance[edge.provenance], nil)
    seen_ids[edge.id] = true
    seen_edges[edge] = true
    seen_sources[edge.source] = true
    seen_provenance[edge.provenance] = true
    counts_by_row[edge.row_id] = (counts_by_row[edge.row_id] or 0) + 1
  end
  for _, row_id in ipairs(empty_rows) do
    t.eq(counts_by_row[row_id] or 0, 0)
  end
end

local function assert_guard_boundary_edges(actual, expected, rows_without_boundaries)
  t.eq(#actual, #expected)
  local seen_ids = {}
  local seen_edges = {}
  local seen_sources = {}
  local seen_provenance = {}
  local counts_by_row = {}
  for index, expected_edge in ipairs(expected) do
    local edge = actual[index]
    local edge_keys = key_set(structural_fields)
    edge_keys.semantic_variant = true
    if expected_edge.cas_policy_id ~= nil then edge_keys.cas_policy_id = true end; if expected_edge.cas_variant ~= nil then edge_keys.cas_variant = true end
    if expected_edge.pending_order ~= nil then edge_keys.pending_order = true end
    if expected_edge.transition_effect_entitlements ~= nil then
      edge_keys.transition_effect_entitlements = true
    end
    assert_exact_keys(edge, edge_keys)
    if expected_edge.source.boundary == nil then
      assert_exact_keys(edge.source, { state = true })
    else
      assert_exact_keys(edge.source, { state = true, boundary = true })
    end
    assert_exact_keys(edge.provenance, { owner = true, row = true, field = true })
    t.eq(edge.id, expected_edge.id)
    t.eq(edge.owner, expected_edge.owner)
    t.eq(edge.row_id, expected_edge.row_id)
    t.eq(edge.kind, expected_edge.kind)
    t.eq(edge.source.state, expected_edge.source.state)
    t.eq(edge.source.boundary, expected_edge.source.boundary)
    t.eq(edge.target, expected_edge.target)
    t.eq(edge.semantic_variant, expected_edge.semantic_variant)
    assert_semantic_variant(edge)
    t.eq(edge.cas_policy_id, expected_edge.cas_policy_id); t.eq(edge.cas_variant, expected_edge.cas_variant)
    assert_same_value(edge.pending_order, expected_edge.pending_order)
    assert_same_value(edge.transition_effect_entitlements, expected_edge.transition_effect_entitlements)
    assert_valid_cas(edge)
    t.eq(edge.provenance.owner, expected_edge.provenance.owner)
    t.eq(edge.provenance.row, expected_edge.provenance.row)
    t.eq(edge.provenance.field, expected_edge.provenance.field)
    t.eq(seen_ids[edge.id], nil)
    t.eq(seen_edges[edge], nil)
    t.eq(seen_sources[edge.source], nil)
    t.eq(seen_provenance[edge.provenance], nil)
    seen_ids[edge.id] = true
    seen_edges[edge] = true
    seen_sources[edge.source] = true
    seen_provenance[edge.provenance] = true
    counts_by_row[edge.row_id] = (counts_by_row[edge.row_id] or 0) + 1
  end
  for _, row_id in ipairs(rows_without_boundaries) do
    t.eq(counts_by_row[row_id] or 0, 0)
  end
end

local function assert_timeout_edges(actual, expected)
  t.eq(#actual, #expected)
  local seen_ids = {}
  for index, expected_edge in ipairs(expected) do
    local edge = actual[index]
    local edge_keys = key_set(structural_fields)
    edge_keys.semantic_variant = true
    edge_keys.timeout_evidence_policy_id = true
    if expected_edge.transition_effect_entitlements ~= nil then edge_keys.transition_effect_entitlements = true end
    if expected_edge.pending_order ~= nil then edge_keys.pending_order = true end
    if expected_edge.cas_policy_id ~= nil then edge_keys.cas_policy_id = true end
    if expected_edge.cas_variant ~= nil then edge_keys.cas_variant = true end
    assert_exact_keys(edge, edge_keys)
    if expected_edge.source.boundary == nil then
      assert_exact_keys(edge.source, { state = true })
    else
      assert_exact_keys(edge.source, { state = true, boundary = true })
    end
    assert_exact_keys(edge.provenance, { owner = true, row = true, field = true })
    t.eq(edge.id, expected_edge.id)
    t.eq(edge.owner, expected_edge.owner)
    t.eq(edge.row_id, expected_edge.row_id)
    t.eq(edge.kind, "timeout")
    t.eq(edge.source.state, expected_edge.source.state)
    t.eq(edge.source.boundary, expected_edge.source.boundary)
    t.eq(edge.target, expected_edge.target)
    t.eq(edge.semantic_variant, expected_edge.semantic_variant)
    assert_semantic_variant(edge)
    t.eq(edge.timeout_evidence_policy_id, expected_edge.timeout_evidence_policy_id)
    t.eq(edge.cas_policy_id, expected_edge.cas_policy_id)
    t.eq(edge.cas_variant, expected_edge.cas_variant)
    assert_same_value(edge.transition_effect_entitlements, expected_edge.transition_effect_entitlements)
    assert_same_value(edge.pending_order, expected_edge.pending_order)
    assert_valid_cas(edge)
    t.eq(edge.provenance.owner, expected_edge.provenance.owner)
    t.eq(edge.provenance.row, expected_edge.provenance.row)
    t.eq(edge.provenance.field, expected_edge.provenance.field)
    t.eq(seen_ids[edge.id], nil)
    seen_ids[edge.id] = true
  end
end

local function assert_successor_kind_partition(rows)
  local seen = {}
  for _, row in ipairs(rows) do
    for _, successor in ipairs(row.responsibility_signature.successors) do
      local key = row.from_state .. "/" .. tostring(successor.output_variant)
      t.eq(successor.kind, expected_successor_kinds[key])
      t.eq(seen[key], nil)
      seen[key] = true
    end
  end
  local expected_count = 0
  for key in pairs(expected_successor_kinds) do
    expected_count = expected_count + 1
    t.eq(seen[key], true)
  end
  local actual_count = 0
  for _ in pairs(seen) do
    actual_count = actual_count + 1
  end
  t.eq(actual_count, expected_count)
end

local function tuple_key(owner, source_state, target, output_variant)
  local state_key = source_state == nil and "\0" or "\1" .. source_state
  return table.concat({ owner, state_key, target, output_variant }, "\2")
end

local function output_variant_from_id(id)
  local output_variant = tostring(id):match("/([^/]+)$")
  t.is_true(output_variant ~= nil)
  return output_variant
end

local function sorted_set_bytes(values)
  local keys = {}
  for key in pairs(values) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return table.concat(keys, "\n")
end

local function legacy_union_bytes(owner, rows, inventory)
  local tuples = {}
  for _, row in ipairs(rows) do
    for _, successor in ipairs(row.responsibility_signature.successors) do
      tuples[tuple_key(owner, row.from_state, successor.state, successor.output_variant)] = true
    end
    for _, guard_boundary in ipairs(row.guard_boundaries or {}) do
      for _, successor in ipairs(guard_boundary.successors) do
        tuples[tuple_key(owner, row.from_state, successor.state, successor.output_variant)] = true
      end
    end
    for _, activation in ipairs(row.receiver_activations or {}) do
      tuples[tuple_key(owner, row.from_state, activation.target, activation.output_variant)] = true
    end
  end
  for _, entry in ipairs(inventory) do
    tuples[tuple_key(owner, nil, entry.target, entry.semantic_variant)] = true
  end
  return sorted_set_bytes(tuples)
end

local function extracted_union_bytes(owner, rows, inventory)
  local tuples = {}
  local extracted = {
    restart_edges.extract_autonomous_edges(owner, rows),
    restart_edges.extract_guard_boundary_edges(owner, rows),
    restart_edges.extract_timeout_edges(owner, rows),
    restart_edges.extract_entry_edges(owner, inventory, rows),
  }
  for _, edges in ipairs(extracted) do
    for _, edge in ipairs(edges) do
      assert_semantic_variant(edge)
      tuples[tuple_key(edge.owner, edge.source.state, edge.target, output_variant_from_id(edge.id))] = true
    end
  end
  return sorted_set_bytes(tuples)
end

local function row(from_state, successors)
  return {
    from_state = from_state,
    responsibility_signature = { successors = successors },
  }
end

local function guard_row(from_state, guard_boundaries)
  return {
    from_state = from_state,
    guard_boundaries = guard_boundaries,
  }
end

local function assert_extract_fails(owner, rows)
  local ok = pcall(function()
    restart_edges.extract_autonomous_edges(owner, rows)
  end)
  t.eq(ok, false)
end

local function assert_guard_extract_fails(owner, rows)
  local ok = pcall(function()
    restart_edges.extract_guard_boundary_edges(owner, rows)
  end)
  t.eq(ok, false)
end

local function assert_timeout_extract_fails(owner, rows)
  local ok = pcall(function()
    restart_edges.extract_timeout_edges(owner, rows)
  end)
  t.eq(ok, false)
end

local function row_by_state(rows, state)
  for _, candidate in ipairs(rows) do
    if candidate.from_state == state then
      return candidate
    end
  end
  return nil
end

return {
  h = h,
  entry_inventory = entry_inventory,
  restart_cas_catalog = restart_cas_catalog,
  restart_edges = restart_edges,
  core = core,
  t = t,
  structural_fields = structural_fields,
  deferred_kinds = deferred_kinds,
  expected_successor_kinds = expected_successor_kinds,
  expected_real_cas_by_id = expected_real_cas_by_id,
  expected_guard_boundary_cas_by_id = expected_guard_boundary_cas_by_id,
  key_set = key_set,
  empty_entitlements = empty_entitlements,
  assert_exact_keys = assert_exact_keys,
  assert_semantic_variant = assert_semantic_variant,
  copy_value = copy_value,
  assert_same_value = assert_same_value,
  assert_valid_cas = assert_valid_cas,
  expected_edges = expected_edges,
  expected_guard_boundary_edges = expected_guard_boundary_edges,
  timeout_policy_by_source = timeout_policy_by_source,
  expected_timeout_edges = expected_timeout_edges,
  assert_edges = assert_edges,
  assert_guard_boundary_edges = assert_guard_boundary_edges,
  assert_timeout_edges = assert_timeout_edges,
  assert_successor_kind_partition = assert_successor_kind_partition,
  tuple_key = tuple_key,
  output_variant_from_id = output_variant_from_id,
  sorted_set_bytes = sorted_set_bytes,
  legacy_union_bytes = legacy_union_bytes,
  extracted_union_bytes = extracted_union_bytes,
  row = row,
  guard_row = guard_row,
  assert_extract_fails = assert_extract_fails,
  assert_guard_extract_fails = assert_guard_extract_fails,
  assert_timeout_extract_fails = assert_timeout_extract_fails,
  row_by_state = row_by_state,
}
