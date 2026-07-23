local devloop_state = require("devloop.state")
local ra = require("tests.receiver_activation_observation_helpers")
local restart_metadata = require("devloop.restart_metadata")

local t = fkst.test
local PREFIX = "fact-old-pending-projection-"
local SITE = {
  path = "libraries/devloop/state.lua",
  symbol = "can_reach",
  ordinal = "transition_status:pending-projection",
}
local FIXTURES = {
  {
    disposition = "exact-graph",
    status = "read",
    reason = "exact-old-pending-projection",
    cas = "not-applicable",
    target = "pending-reachability",
    effects = {},
  },
}

local function pending_edges()
  local predecessors = ra.json_array({ "unmanaged" })
  for _, state in ipairs(restart_metadata.state_order()) do table.insert(predecessors, state) end
  local edges = ra.json_array()
  for _, predecessor in ipairs(predecessors) do
    for _, target in ipairs(restart_metadata.state_successors(predecessor) or {}) do
      local status = devloop_state.transition_status(
        { state = predecessor },
        { target },
        "__pending_projection_probe__"
      )
      local expected = predecessor == target and "apply" or "pending"
      t.eq(status, expected, predecessor .. "->" .. target .. ": OLD transition_status outcome")
      table.insert(edges, {
        edge = predecessor .. "->" .. target,
        transition_status = status,
      })
    end
  end
  table.sort(edges, function(left, right) return left.edge < right.edge end)
  return edges
end

local function capture(fixture)
  local edges = pending_edges()
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = PREFIX .. fixture.disposition,
    owner = "devloop",
    site = ra.copy_value(SITE),
    boundary = "owner_observation_fact",
    typed_intent = {
      kind = "legacy_pending_projection_read",
      source_state = ra.JSON_NULL,
      source_boundary = "source-module",
      target = fixture.target,
      cause_schema_id = "restart-metadata-observation.v1",
      generation_epoch = { snapshot_basis = "OLD source module at test dispatch" },
      lineage = { owner = "devloop", observation_id = PREFIX .. fixture.disposition },
    },
    old_inputs = {
      current_fact = { source_graph_edge_count = #edges },
      caller_from_states = ra.json_array(),
      incoming_version = "source-snapshot:v1",
      target_version = ra.JSON_NULL,
      handoff_reference = ra.JSON_NULL,
    },
    old_outcome = {
      status = fixture.status,
      reason_code = fixture.reason,
      cas_outcome = fixture.cas,
      emitted_effects = ra.json_array(),
      observable_writes = { projection_edges = edges },
      handoff_direct_lookup_count = 0,
      timeout_evidence_source = ra.JSON_NULL,
    },
    evidence_refs = ra.json_array({
      { kind = "old-pending-classifier", ref = "libraries/devloop/state.lua:281-322" },
      { kind = "old-state-graph", ref = "libraries/devloop/state_labels.lua:25-43" },
    }),
  }
end

return {
  test_old_pending_projection_is_real_old_source_bound_and_bidirectional = function()
    ra.assert_site(t, {
      dept = "old-pending-projection",
      fixtures = FIXTURES,
      capture = capture,
      prefix = PREFIX,
      site = SITE,
      boundary = "owner_observation_fact",
    })
  end,
}
