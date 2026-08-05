local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local h = require("tests.devloop_helpers")

local core = h.core
local find_raise = h.find_raise
local issue = h.issue
local mock_issue_state = h.mock_issue_state
local opts = h.opts
local run_observe = h.run_observe
local t = h.t

local proposal_id = "github-devloop/issue/owner/repo/42"
local source_ref = { kind = "external", ref = "owner/repo#issue/42" }

local function angles()
  return {
    { angle = "minimal", verdict = "abstain", digest = "same-digest" },
  }
end

return {
  test_observe_replay_ignores_prior_thinking_epoch_true_stall = function()
    local current_epoch = proposal_id .. "/2026-06-03T01-02-05Z/reimplement/2"
    local previous_epoch = proposal_id .. "/2026-06-03T01-02-03Z/reimplement/1"
    local source_digest = convergence_shared.source_ref_digest(source_ref)
    local comments = {
      {
        body = core.state_marker(proposal_id, "thinking", current_epoch),
        created_at = "2026-06-03T01:02:05Z",
      },
    }
    for round = 1, 3 do
      table.insert(comments, {
        body = conv_rounds.converge_round_marker(
          proposal_id,
          previous_epoch,
          source_digest,
          round,
          "consensus:previous-thinking/loop/" .. tostring(round),
          "Previous epoch question " .. tostring(round),
          angles()
        ),
        created_at = "2026-06-03T01:01:0" .. tostring(round) .. "Z",
      })
    end
    mock_issue_state(
      { "fkst-dev:enabled", "fkst-dev:thinking" },
      "OPEN",
      comments
    )

    local result = run_observe(issue({
      updated_at = "2026-06-03T01:02:05Z",
      labels = { "fkst-dev:enabled", "fkst-dev:thinking" },
    }), opts("observe-fresh-thinking-epoch"))

    t.eq(result.exit_code, 0)
    local proposal = find_raise(result.raises, "devloop_consensus_request")
    t.is_true(proposal ~= nil)
    -- #3104 gave each thinking redrive its own delivery identity: dedup_key now carries the
    -- redrive lineage while effect_version stays the logical epoch. Assert the epoch on
    -- effect_version, and that dedup_key is distinct, matching the sibling tests adapted there.
    t.eq(proposal.payload.effect_version, current_epoch)
    t.is_true(proposal.payload.dedup_key ~= nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    local reconcile = find_raise(
      result.raises,
      "github-proxy.github_issue_comment_request",
      function(payload)
        return type(payload.handoff) == "table"
          and payload.handoff.kind == "github-devloop.reconcile"
      end
    )
    t.eq(reconcile, nil)
  end,
}
