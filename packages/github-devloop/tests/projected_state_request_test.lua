local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local requests_labels = require("devloop.requests.labels")
local h = require("tests.devloop_helpers")

local t = h.t

local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local source_ref = entity_lib.issue_source_ref("owner/repo", 42)

local function build_request(state, additions, removals)
  return devloop_state.build_projected_state_comment_request({
    repo = "owner/repo",
    issue_number = 42,
    proposal_id = proposal_id,
    state = state,
    marker_version = version,
    handoff_version = version,
    effects = state == "ready"
      and "result-marker,ready-label,devloop-ready"
      or "ready-split-canonicalized",
    body_before_marker = "projection prefix\n",
    body_after_marker = "\nprojection suffix",
    comment_dedup_key = "projected-state/comment/" .. state,
    label_policy = {
      dedup_key = "projected-state/label/" .. state,
      add_labels = additions,
      remove_labels = removals,
    },
    source_ref = source_ref,
  })
end

local function has_value(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then return true end
  end
  return false
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

return {
  test_raw_state_marker_rejects_projected_state_creation = function()
    for _, state in ipairs({ "ready", "dependency_wait" }) do
      t.raises(function()
        devloop_state.state_marker(proposal_id, state, version)
      end)
    end
  end,

  test_projected_state_constructor_embeds_matching_guarded_label_handoff = function()
    for _, fixture in ipairs({
      { state = "ready", add = {}, remove = { "fkst-dev:blocked-on-dependency" } },
      { state = "dependency_wait", add = { "fkst-dev:blocked-on-dependency" }, remove = {} },
    }) do
      local request = build_request(fixture.state, fixture.add, fixture.remove)
      local handoff = request.handoff
      local label = handoff and handoff.label_request

      t.eq(request.schema, "github-proxy.v1")
      t.eq(request.state_marker, nil)
      t.eq(request.label_request, nil)
      t.is_true(request.body:find('state="' .. fixture.state .. '"', 1, true) ~= nil)
      t.eq(handoff.proposal_id, proposal_id)
      t.eq(handoff.marker_version, version)
      t.eq(label.require_marker_guard, true)
      t.eq(label.expected_proposal_id, proposal_id)
      t.eq(label.expected_state, fixture.state)
      t.eq(label.expected_version, version)
      t.eq(label.marker_guard.match.proposal, proposal_id)
      t.eq(label.marker_guard.expected.state, fixture.state)
      t.eq(label.marker_guard.expected.version, version)
      t.eq(label.marker_guard.marker_target.kind, "issue")
      t.eq(label.marker_guard.marker_target.number, 42)
      for _, expected in ipairs(fixture.add) do
        t.is_true(has_value(label.add_labels, expected))
      end
      for _, expected in ipairs(fixture.remove) do
        t.is_true(has_value(label.remove_labels, expected))
      end
    end
  end,

  test_projected_state_guard_requires_the_canonical_marker_family = function()
    local guard = build_request("ready").handoff.label_request.marker_guard
    t.eq(requests_labels.is_canonical_state_marker_guard(guard), true)

    local mutations = {
      function(value) value.namespace = "other" end,
      function(value) value.marker = "result" end,
      function(value) value.version = "v2" end,
      function(value) value.order_by = { "version_order_key", "marker_order_key", "stage_rank" } end,
      function(value) value.order_by = { "marker_order_key", "version_order_key" } end,
      function(value)
        value.order_by = { "marker_order_key", "version_order_key", "stage_rank", "comment_id" }
      end,
    }
    for _, mutate in ipairs(mutations) do
      local noncanonical = copy(guard)
      mutate(noncanonical)
      t.eq(requests_labels.is_canonical_state_marker_guard(noncanonical), false)
    end
  end,
}
