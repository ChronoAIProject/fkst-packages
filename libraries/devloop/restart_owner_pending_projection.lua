local pending_projection = require("devloop.restart_pending_projection")
local restart_edges = require("devloop.restart_edges")
local restart_metadata = require("devloop.restart_metadata")

local M = {}

local frozen_predecessors = {
  "unmanaged",
  "thinking",
  "dependency_wait",
  "ready",
  "implementing",
  "awaiting-pr",
  "pr-open",
  "reviewing",
  "merge-ready",
  "merging",
  "fixing",
  "review-meta",
  "impl-failed",
  "merged",
  "closed-unmerged",
  "blocked",
}

local excluded_successors = {
  thinking = { declined = true },
  fixing = { blocked = true },
}

local frozen_projection = {}
for _, predecessor in ipairs(frozen_predecessors) do
  local targets = {}
  local excluded = excluded_successors[predecessor] or {}
  for _, target in ipairs(restart_metadata.state_successors(predecessor)) do
    if excluded[target] ~= true then
      targets[target] = true
    end
  end
  frozen_projection[predecessor] = targets
end

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, nested in pairs(value) do
    copy[key] = deep_copy(nested)
  end
  return copy
end

local owner_sources = {
  ["github-devloop"] = {
    unmanaged = true,
    thinking = true,
    dependency_wait = true,
    ready = true,
    implementing = true,
    ["awaiting-pr"] = true,
    ["impl-failed"] = true,
  },
  ["github-devloop-pr"] = {
    ["pr-open"] = true,
    reviewing = true,
    ["merge-ready"] = true,
    merging = true,
    fixing = true,
    ["review-meta"] = true,
  },
}

local edge_witness_sources = {
  ["github-devloop"] = "packages/github-devloop/tests/restart_edges_conformance_test.lua",
  ["github-devloop-pr"] = "packages/github-devloop-pr/tests/restart_edges_conformance_test.lua",
}

local entitlement_witness_sources = {
  ["github-devloop"] = {
    extraction = "packages/github-devloop/tests/restart_edges_conformance_test.lua",
    grant = "packages/github-devloop/tests/restart_effects_grant_seal_test.lua",
  },
  ["github-devloop-pr"] = {
    extraction = "packages/github-devloop-pr/tests/restart_edges_conformance_test.lua",
    grant = "packages/github-devloop-pr/tests/restart_effects_grant_seal_test.lua",
  },
}

local timeout_witness_sources = {
  ["github-devloop"] = "packages/github-devloop/tests/restart_edges_conformance_test.lua",
  ["github-devloop-pr"] = "packages/github-devloop-pr/tests/restart_edges_conformance_test.lua",
}

local function append_all(target, values)
  for _, value in ipairs(values) do
    table.insert(target, value)
  end
end

function M.edges(owner, rows, inventories)
  local edges = {}
  append_all(edges, restart_edges.extract_autonomous_edges(owner, rows))
  append_all(edges, restart_edges.extract_guard_boundary_edges(owner, rows))
  append_all(edges, restart_edges.extract_timeout_edges(owner, rows))
  append_all(edges, restart_edges.extract_entry_edges(owner, inventories.entry, rows))
  append_all(edges, restart_edges.extract_operator_reentry_edges(owner, inventories.operator_reentry))
  append_all(edges, restart_edges.extract_canonicalization_edges(owner, inventories.canonicalization))
  return edges
end

function M.derive(owner, rows, inventories)
  return pending_projection.derive_pending_projection(M.edges(owner, rows, inventories))
end

function M.frozen_projection()
  return deep_copy(frozen_projection)
end

local function expected_owner_projection(owner)
  local projection = {}
  for predecessor in pairs(owner_sources[owner] or {}) do
    local targets = frozen_projection[predecessor] or {}
    for target in pairs(targets) do
      projection[predecessor] = projection[predecessor] or {}
      projection[predecessor][target] = true
    end
  end
  return projection
end

function M.frozen_edge_witness_index(owner, edges)
  local source_path = edge_witness_sources[owner]
  if source_path == nil then
    error("devloop.restart_owner_pending_projection: unknown lifecycle owner " .. tostring(owner))
  end
  if type(edges) ~= "table" then
    error("devloop.restart_owner_pending_projection: edges must be an array")
  end

  local witnesses = {}
  for _, edge in ipairs(edges) do
    local pending_order = type(edge) == "table" and edge.pending_order or nil
    local predecessor_state = type(pending_order) == "table"
      and pending_order.predecessor_state or nil
    if type(edge) ~= "table"
        or edge.owner ~= owner
        or type(edge.id) ~= "string" or edge.id == ""
        or type(pending_order) ~= "table"
        or type(pending_order.participates) ~= "boolean"
        or (predecessor_state ~= nil
          and (type(predecessor_state) ~= "string" or predecessor_state == ""))
        or (pending_order.participates and predecessor_state == nil)
        or type(edge.target) ~= "string" or edge.target == ""
        or type(edge.kind) ~= "string" or edge.kind == "" then
      error("devloop.restart_owner_pending_projection: edge witness identity is invalid")
    end
    if witnesses[edge.id] ~= nil then
      error("devloop.restart_owner_pending_projection: duplicate edge witness id " .. edge.id)
    end
    witnesses[edge.id] = {
      owner = owner,
      edge_id = edge.id,
      predecessor_state = predecessor_state,
      target = edge.target,
      kind = edge.kind,
      input_fixture_id = edge.id,
      expected_decision = {
        predecessor_state = predecessor_state,
        target = edge.target,
        kind = edge.kind,
      },
      expected_effect_ids = {},
      expected_payload_obligations = {},
      witness_id = source_path .. "#edge:" .. edge.id,
    }
  end
  return witnesses
end

function M.frozen_pending_witness_index(owner, edges)
  if owner_sources[owner] == nil then
    error("devloop.restart_owner_pending_projection: unknown lifecycle owner " .. tostring(owner))
  end
  if type(edges) ~= "table" then
    error("devloop.restart_owner_pending_projection: edges must be an array")
  end

  local expected = expected_owner_projection(owner)
  local witnesses = {}
  for _, edge in ipairs(edges) do
    local pending_order = type(edge) == "table" and edge.pending_order or nil
    if type(pending_order) == "table" and pending_order.participates == true then
      local predecessor = pending_order.predecessor_state
      local targets = expected[predecessor]
      if type(targets) == "table" and targets[edge.target] == true then
        if witnesses[edge.id] ~= nil then
          error("devloop.restart_owner_pending_projection: duplicate pending edge id " .. tostring(edge.id))
        end
        local fixture_id = predecessor .. "->" .. edge.target
        witnesses[edge.id] = {
          owner = owner,
          edge_id = edge.id,
          predecessor_state = predecessor,
          target = edge.target,
          input_fixture_id = fixture_id,
          expected_decision = {
            participates = true,
            predecessor_state = predecessor,
            target = edge.target,
          },
          expected_effect_ids = {},
          expected_payload_obligations = {},
          witness_id = "libraries/devloop/restart_owner_pending_projection.lua#"
            .. owner .. "/" .. fixture_id,
        }
      end
    end
  end
  return witnesses
end

local function entitlement_expected_effect_ids(entitlements)
  local effect_ids = {}
  local seen = {}
  for _, status in ipairs({ "apply", "idempotent" }) do
    for _, effect_id in ipairs(entitlements[status].effect_ids) do
      if not seen[effect_id] then
        seen[effect_id] = true
        table.insert(effect_ids, effect_id)
      end
    end
  end
  return effect_ids
end

function M.frozen_entitlement_witness_index(owner, edges)
  local sources = entitlement_witness_sources[owner]
  if sources == nil then
    error("devloop.restart_owner_pending_projection: unknown lifecycle owner " .. tostring(owner))
  end
  if type(edges) ~= "table" then
    error("devloop.restart_owner_pending_projection: edges must be an array")
  end

  local witnesses = {}
  for _, edge in ipairs(edges) do
    local entitlements = type(edge) == "table" and edge.transition_effect_entitlements or nil
    if type(entitlements) == "table" and next(entitlements) ~= nil then
      if edge.owner ~= owner or type(edge.id) ~= "string" or edge.id == "" then
        error("devloop.restart_owner_pending_projection: entitlement edge identity is invalid")
      end
      if witnesses[edge.id] ~= nil then
        error("devloop.restart_owner_pending_projection: duplicate entitlement edge id " .. edge.id)
      end
      witnesses[edge.id] = {
        owner = owner,
        edge_id = edge.id,
        input_fixture_id = edge.id .. "/apply-idempotent",
        expected_decision = {
          apply = {
            effect_entitlement_id = entitlements.apply.id,
            granted_effect_ids = deep_copy(entitlements.apply.effect_ids),
          },
          idempotent = {
            effect_entitlement_id = entitlements.idempotent.id,
            granted_effect_ids = deep_copy(entitlements.idempotent.effect_ids),
          },
        },
        expected_effect_ids = entitlement_expected_effect_ids(entitlements),
        expected_payload_obligations = {},
        witness_id = sources.extraction .. "#transition_effect_entitlements:" .. edge.id
          .. "|" .. sources.grant .. "#grant-seal",
      }
    end
  end
  return witnesses
end

function M.frozen_timeout_witness_index(owner, rows, edges)
  local source_path = timeout_witness_sources[owner]
  if source_path == nil then
    error("devloop.restart_owner_pending_projection: unknown lifecycle owner " .. tostring(owner))
  end
  if type(rows) ~= "table" then
    error("devloop.restart_owner_pending_projection: rows must be an array")
  end
  if type(edges) ~= "table" then
    error("devloop.restart_owner_pending_projection: edges must be an array")
  end

  local rows_by_id = {}
  for _, row in ipairs(rows) do
    if type(row) ~= "table" or type(row.from_state) ~= "string" or row.from_state == "" then
      error("devloop.restart_owner_pending_projection: timeout witness row identity is invalid")
    end
    if rows_by_id[row.from_state] ~= nil then
      error("devloop.restart_owner_pending_projection: duplicate timeout witness row id " .. row.from_state)
    end
    rows_by_id[row.from_state] = row
  end

  local witnesses = {}
  for _, edge in ipairs(edges) do
    if type(edge) == "table" and edge.timeout_evidence_policy_id ~= nil then
      if edge.owner ~= owner or type(edge.id) ~= "string" or edge.id == ""
          or type(edge.row_id) ~= "string" or edge.row_id == ""
          or type(edge.timeout_evidence_policy_id) ~= "string"
          or edge.timeout_evidence_policy_id == "" then
        error("devloop.restart_owner_pending_projection: timeout edge identity is invalid")
      end
      if witnesses[edge.id] ~= nil then
        error("devloop.restart_owner_pending_projection: duplicate timeout edge id " .. edge.id)
      end
      local row = rows_by_id[edge.row_id]
      local actionable_epoch = type(row) == "table" and row.actionable_epoch or nil
      local actionable_epoch_source = type(actionable_epoch) == "table"
        and actionable_epoch.source or nil
      if type(actionable_epoch_source) == "string" and actionable_epoch_source ~= "" then
        witnesses[edge.id] = {
          owner = owner,
          edge_id = edge.id,
          actionable_epoch_source = actionable_epoch_source,
          resolver = edge.timeout_evidence_policy_id,
          input_fixture_id = edge.id .. "/timeout-resolver",
          expected_decision = {
            actionable_epoch_source = actionable_epoch_source,
            resolver = edge.timeout_evidence_policy_id,
          },
          expected_effect_ids = {},
          expected_payload_obligations = {},
          witness_id = source_path .. "#timeout_evidence_policy_id:" .. edge.id,
        }
      end
    end
  end
  return witnesses
end

local function union(left, right)
  local projection = {}
  for _, candidate in ipairs({ left, right }) do
    for predecessor, targets in pairs(candidate) do
      projection[predecessor] = projection[predecessor] or {}
      for target in pairs(targets) do
        projection[predecessor][target] = true
      end
    end
  end
  return projection
end

local function projection_bytes(projection)
  local lines = {}
  for predecessor, targets in pairs(projection) do
    for target in pairs(targets) do
      table.insert(lines, predecessor .. "->" .. target)
    end
  end
  table.sort(lines)
  return table.concat(lines, "\n")
end

function M.owner_errors(owner, projection)
  local sources = owner_sources[owner]
  if sources == nil then
    return { "pending projection has unknown lifecycle owner: " .. tostring(owner) }
  end
  local expected = expected_owner_projection(owner)
  local errors = {}
  if projection_bytes(projection) ~= projection_bytes(expected) then
    table.insert(errors, owner .. " pending projection differs from its frozen source subset")
  end

  local peer = owner == "github-devloop" and "github-devloop-pr" or "github-devloop"
  local composed = union(projection, expected_owner_projection(peer))
  if projection_bytes(composed) ~= projection_bytes(frozen_projection) then
    table.insert(errors, owner .. " pending projection union does not equal the frozen projection")
  end
  return errors
end

return M
