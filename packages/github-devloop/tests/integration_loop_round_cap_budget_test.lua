local convergence_shared = require("devloop.convergence.shared")
local h = require("tests.devloop_helpers")
local conv_rounds = require("devloop.convergence.rounds")
local t = h.t
local core = h.core
local opts = h.opts
local unresolved = h.unresolved
local run_loop = h.run_loop
local mock_issue_loop = h.mock_issue_loop
local find_raise = h.find_raise
local take_consensus_proposal = h.take_consensus_proposal

local function angles(round, verdict)
  return {
    { angle = "minimal", verdict = verdict or "abstain", digest = "digest-" .. tostring(round or 0) },
  }
end

local function findings(text)
  return "open:\n" .. tostring(text or "current unresolved finding")
end

return {
  test_loop_first_converge_raises_one_evidence_continuation = function()
    local base_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local event = unresolved({
      dedup_key = base_version,
      round = 0,
      narrowed_question = "Which dependency evidence resolves the gap?",
      angle_digests = angles(0),
      findings_record = findings("dependency evidence remains unresolved"),
    })
    mock_issue_loop({ "fkst-dev:thinking" }, {
      h.state_comment_request(event.proposal_id, "thinking", base_version).body,
    })

    local result = run_loop(event, opts("loop-first-evidence-continuation"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    local proposal = take_consensus_proposal()
    t.is_true(proposal ~= nil)
    t.eq(proposal.round, 1)
    t.eq(proposal.dedup_key, "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/1")
    t.eq(proposal.convergence_question, event.narrowed_question)
    t.eq(proposal.findings_record, event.findings_record)
    t.eq(proposal.prior_round_digests, nil)
    t.is_true(find_raise(result.raises, "devloop_consensus_request") ~= nil)

    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment ~= nil)
    t.is_nil(comment.payload.handoff)
    t.is_true(comment.payload.body:find('round="0"', 1, true) ~= nil)
    t.is_true(comment.payload.body:find('findings_record="open:%0Adependency evidence remains unresolved"', 1, true) ~= nil)
  end,

  test_loop_evidence_continuation_budget_redrives_next_round = function()
    local base_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local event = unresolved({
      dedup_key = base_version .. "/loop/1",
      round = 1,
      narrowed_question = "Which dependency evidence resolves the gap now?",
      angle_digests = angles(1),
      findings_record = findings("second resolvable finding"),
    })
    local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
    mock_issue_loop({ "fkst-dev:thinking" }, {
      h.state_comment_request(event.proposal_id, "thinking", base_version).body,
      conv_rounds.converge_round_marker(event.proposal_id, base_version, sr_digest, 0, base_version, "First boundary", angles(0), findings("first resolvable finding")),
    })

    local result = run_loop(event, opts("loop-evidence-continuation-budget"))
    t.eq(result.exit_code, 0)
    -- Owner directive (#2725): the evidence-continuation ROUND-BUDGET is a raw counter
    -- that must NEVER hand off a terminal reconcile; with two DISTINCT resolvable rounds
    -- (not a true-stall) convergence REDRIVES the next round instead of dropping to
    -- blocked. No terminal reconcile handoff is emitted.
    t.eq(#result.raises, 2)
    local proposal = take_consensus_proposal()
    t.is_true(proposal ~= nil)
    t.eq(proposal.round, 2)
    t.eq(proposal.dedup_key, "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/2")
    t.is_true(find_raise(result.raises, "devloop_consensus_request") ~= nil)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment ~= nil)
    t.is_nil(comment.payload.handoff)
    t.is_true(comment.payload.body:find('round="1"', 1, true) ~= nil)
  end,

  test_loop_proposal_lineage_budget_survives_version_and_source_ref_drift = function()
    local base_version = "consensus:github-devloop/issue/owner/repo/42/intake/current"
    local drift_version = "consensus:github-devloop/issue/owner/repo/42/intake/drifted"
    local event = unresolved({
      dedup_key = base_version .. "/loop/3",
      round = 3,
      source_ref = { kind = "external", ref = "owner/repo#issue/42?current=1" },
      narrowed_question = "Current boundary question",
      angle_digests = angles(0),
    })
    local current_digest = convergence_shared.source_ref_digest(event.source_ref)
    local drift_digest = convergence_shared.source_ref_digest({ kind = "external", ref = "owner/repo#issue/42?drift=1" })
    mock_issue_loop({ "fkst-dev:thinking" }, {
      h.state_comment_request(event.proposal_id, "thinking", base_version).body,
      {
        body = conv_rounds.converge_round_marker(event.proposal_id, base_version, current_digest, 1, base_version .. "/loop/1", "Forged", angles(1), findings("forged finding")),
        author_login = "ordinary-user",
      },
      conv_rounds.converge_round_marker(event.proposal_id, drift_version, drift_digest, 1, drift_version .. "/loop/1", "Other boundary", angles(1), findings("drifted finding")),
    })

    local result = run_loop(event, opts("loop-drifted-lineage-budget"))
    t.eq(result.exit_code, 0)
    -- Owner directive (#2725): the round-budget is non-terminal. The forged non-bot
    -- round-1 marker is still ignored and only the drifted bot lineage (round 1) counts,
    -- but the incoming round 3 is a gap ahead of that head -- a plain idempotent skip,
    -- not a terminal reconcile handoff (never drops to blocked).
    t.eq(#result.raises, 0)
  end,

  test_loop_essence_stall_handoffs_terminal_reconcile_without_continuation = function()
    local base_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local event = unresolved({
      dedup_key = base_version,
      round = 0,
      narrowed_question = "essence-stall + no source-verifiable evidence remains",
      angle_digests = angles(0),
      findings_record = findings("no source-verifiable evidence remains"),
      essence_stall = true,
    })
    mock_issue_loop({ "fkst-dev:thinking" }, {
      h.state_comment_request(event.proposal_id, "thinking", base_version).body,
    })

    local result = run_loop(event, opts("loop-essence-stall"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(take_consensus_proposal(), nil)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment ~= nil)
    t.eq(comment.payload.handoff.kind, "github-devloop.reconcile")
    t.eq(comment.payload.handoff.round, 0)
    t.is_true(comment.payload.body:find('essence_stall="true"', 1, true) ~= nil)
  end,
}
