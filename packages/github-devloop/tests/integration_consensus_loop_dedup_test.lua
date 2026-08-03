local h = require("tests.devloop_helpers")
local conv_rounds = require("devloop.convergence.rounds")
local t = h.t
local core = h.core
local opts = h.opts
local unresolved = h.unresolved
local run_loop = h.run_loop
local mock_issue_loop = h.mock_issue_loop
local find_raise = h.find_raise

return {
  test_loop_reraised_proposal_dedup_follows_consensus_lineage_not_current_updated_at = function()
    local base_version = "consensus:github-devloop/issue/owner/repo/42/intake/1234567890"
    mock_issue_loop({ "fkst-dev:thinking" }, {
      h.state_marker("github-devloop/issue/owner/repo/42", "thinking", base_version),
    }, {
      updated_at = "2026-06-14T01:02:03Z",
    })

    local event = unresolved({
      dedup_key = base_version,
      narrowed_question = "Can this proceed after narrowing?",
      angle_digests = {
        { angle = "minimal", verdict = "abstain", digest = "needs-specificity" },
      },
    })
    h.mock_next_consensus_result(function(proposal)
      return h.reached({
        status = "reached",
        dedup_key = "consensus:" .. proposal.dedup_key,
        effect_version = proposal.effect_version,
        source_ref = proposal.source_ref,
      })
    end)
    local result = run_loop(event, opts("loop-dedup-lineage"))
    local called_proposal = h.take_consensus_proposal()
    t.eq(result.exit_code, 0)
    t.is_true(called_proposal ~= nil)
    t.eq(called_proposal.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(called_proposal.dedup_key, conv_rounds.converge_proposal_base_dedup(base_version) .. "/loop/1")
    t.eq(called_proposal.round, 1)
    t.eq(called_proposal.convergence_question, event.narrowed_question)
    t.eq(called_proposal.source_ref.ref, "owner/repo#issue/42")
    t.is_true(called_proposal.content_fetch:find("runtime-cache:", 1, true) == 1)

    local request = find_raise(result.raises, "devloop_consensus_request").payload
    t.eq(request.schema, "consensus.proposal.v1")
    t.eq(request.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(request.dedup_key, called_proposal.dedup_key)

    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request").payload
    t.is_true(comment.body:find('version="' .. base_version .. '"', 1, true) ~= nil)
    t.is_true(comment.body:find('round="0"', 1, true) ~= nil)
  end,
}
