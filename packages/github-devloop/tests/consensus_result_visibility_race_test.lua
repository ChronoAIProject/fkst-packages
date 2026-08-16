local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local devloop_state = require("devloop.state")
local t = h.t
local core = h.core
local opts = h.opts
local reached = h.reached
local run_result = h.run_result
local mock_issue_result = h.mock_issue_result
local find_raise = h.find_raise
local run_comment_handoff_from_request = h.run_comment_handoff_from_request

local function fold_by_engine_dedup(raised_batches)
  local seen = {}
  local folded = {}
  for _, raises in ipairs(raised_batches) do
    for _, raised in ipairs(raises) do
      local payload = raised.payload or {}
      local key = tostring(raised.queue) .. "\n" .. tostring(payload.dedup_key or "")
      if seen[key] == nil then
        seen[key] = true
        table.insert(folded, raised)
      end
    end
  end
  return folded
end

local function apply_label_requests(initial_labels, raises)
  local labels = {}
  for _, label in ipairs(initial_labels or {}) do
    labels[tostring(label)] = true
  end
  for _, raised in ipairs(raises) do
    if raised.queue == "github-proxy.github_issue_label_request" then
      local payload = raised.payload or {}
      for _, label in ipairs(payload.remove_labels or {}) do
        labels[tostring(label)] = nil
      end
      for _, label in ipairs(payload.add_labels or {}) do
        labels[tostring(label)] = true
      end
    end
  end
  return labels
end

local function bodies_for_comments(raises)
  local bodies = {}
  for _, raised in ipairs(raises) do
    if raised.queue == "github-proxy.github_issue_comment_request" then
      table.insert(bodies, raised.payload.body)
    end
  end
  return bodies
end

return {
  test_consensus_result_divergent_same_lineage_folds_the_authoritative_comment_until_first_ack = function()
    local approve = reached()
    local source_marker = core.state_marker(approve.proposal_id, "thinking", approve.dedup_key)
    mock_issue_result({ "fkst-dev:thinking" }, { source_marker })

    local applied = run_result(approve, opts("visibility-race-first-approve"))
    t.eq(applied.exit_code, 0)
    local approved_comment = find_raise(applied.raises, "github-proxy.github_issue_comment_request")
    local approved_label = approved_comment.payload.handoff.label_request
    t.is_true(approved_comment ~= nil)
    t.eq(find_raise(applied.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(approved_label.expected_state, "ready")
    t.is_true(approved_comment.payload.body:find(m_builders.result_marker(approve.proposal_id, "approve", approve.dedup_key), 1, true) ~= nil)

    local reject = reached({
      decision = "reject",
      decision_reason = "premise-refuted",
      body = "A same-lineage recompute rejects before the first result comment is visible.",
    })
    mock_issue_result({ "fkst-dev:thinking" }, { source_marker })

    local raced = run_result(reject, opts("visibility-race-second-reject-no-visible-first-result"))
    t.eq(raced.exit_code, 0)
    t.eq(#raced.raises, 1)
    local rejected_comment = find_raise(raced.raises, "github-proxy.github_issue_comment_request")
    local rejected_label = rejected_comment.payload.handoff.label_request
    t.is_true(rejected_comment ~= nil)
    t.eq(find_raise(raced.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(rejected_comment.payload.dedup_key, approved_comment.payload.dedup_key)
    t.eq(rejected_label.dedup_key, approved_label.dedup_key)
    t.eq(rejected_label.add_labels[1], "fkst-dev:declined")
    t.is_true(rejected_comment.payload.body:find('state="declined"', 1, true) ~= nil)
    t.is_true(rejected_comment.payload.body:find("fkst:github-devloop:result-divergence:v1", 1, true) == nil)

    -- This models the engine/github-proxy boundary while the first outbound
    -- request delivery row is still pending: same queue + same dedup_key keeps
    -- the first durable row and drops the divergent second payload. If the row
    -- is already ACKed but GitHub has not made the marker visible, this test no
    -- longer claims full closure; the next level poll re-derives from visible
    -- markers and labels.
    local folded = fold_by_engine_dedup({ applied.raises, raced.raises })
    local winning_comment = find_raise(folded, "github-proxy.github_issue_comment_request")
    local acknowledged = run_comment_handoff_from_request(
      winning_comment.payload,
      "IC_visibility_race_winner",
      "visibility-race-winning-comment-handoff"
    )
    t.eq(acknowledged.exit_code, 0)
    local delivered = fold_by_engine_dedup({ applied.raises, raced.raises, acknowledged.raises })
    local labels = apply_label_requests({ "fkst-dev:thinking" }, delivered)

    t.eq(devloop_state.current_state(bodies_for_comments(folded), approve.proposal_id).state, "ready")
    t.eq(labels["fkst-dev:ready"], true)
    t.is_nil(labels["fkst-dev:declined"])
  end,
}
