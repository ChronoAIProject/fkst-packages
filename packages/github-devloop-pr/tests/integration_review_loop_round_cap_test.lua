local devloop_base = require("devloop.base")
local convergence_shared = require("devloop.convergence.shared")
local h = require("tests.devloop_helpers")
local conv_rounds = require("devloop.convergence.rounds")
local t = h.t
local core = h.core
local opts = h.opts
local reviewing = h.reviewing
local review_unresolved = h.review_unresolved
local run_review_loop = h.run_review_loop
local mock_next_consensus_result = h.mock_next_consensus_result
local take_consensus_proposal = h.take_consensus_proposal
local mock_bot_env = h.mock_bot_env
local mock_pr_origin = h.mock_pr_origin
local mock_issue_review = h.mock_issue_review
local find_raise = h.find_raise
local m_builders = require("devloop.markers.builders")

local function angles(round)
  return {
    { angle = "minimal", verdict = "comment", digest = "review-digest-" .. tostring(round or 0) },
  }
end

local function findings(text)
  return "open:\n" .. tostring(text or "review finding remains unresolved")
end

local function issue_proposal_id()
  return "github-devloop/issue/owner/repo/42"
end

local function mock_existing_review_worktree(impl_version)
  local worktree = devloop_base.implement_worktree_path(
    "/tmp/fkst-packages-test/github-devloop/runtime",
    "owner/repo",
    42,
    impl_version
  )
  t.mock_command(core.path_is_directory_cmd(worktree), {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  return worktree
end

local function prepare_review_context(event, comments, head_sha)
  local impl_version = reviewing().version
  local origin_marker = m_builders.pr_origin_marker(issue_proposal_id(), "42", "devloop-owner-repo-42-01HY", impl_version, "dev")
  local pr_comments = {
    origin_marker,
    core.state_marker(issue_proposal_id(), "reviewing", impl_version),
  }
  for _, comment in ipairs(comments or {}) do
    table.insert(pr_comments, comment)
  end
  mock_bot_env()
  mock_pr_origin(pr_comments, "devloop-owner-repo-42-01HY", head_sha or "def456")
  mock_issue_review({ "fkst-dev:reviewing" }, {
    core.state_marker(issue_proposal_id(), "reviewing", impl_version),
  })
  return devloop_base.parse_pr_review_proposal_id(event.proposal_id)
end

return {
  test_review_loop_first_converge_raises_one_evidence_continuation = function()
    local event = review_unresolved({
      dedup_key = "consensus:" .. devloop_base.pr_review_proposal_id("owner/repo", 7, reviewing().version, "def456") .. "/review",
      round = 0,
      narrowed_question = "Which reviewed-head evidence resolves the gap?",
      angle_digests = angles(0),
      findings_record = findings("review evidence remains unresolved"),
    })
    local _, _, review_version = prepare_review_context(event)
    local worktree = mock_existing_review_worktree(reviewing().version)

    mock_next_consensus_result(function(proposal)
      return {
        status = "reached",
        schema = "consensus.consensus_reached.v1",
        decision = "approve",
        body = "The reviewed diff is ready.",
        dedup_key = "consensus:" .. proposal.dedup_key,
        source_ref = proposal.source_ref,
      }
    end)
    local result = run_review_loop(event, opts("review-loop-first-evidence-continuation"))
    local called_proposal = take_consensus_proposal()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.is_true(called_proposal ~= nil)
    t.eq(called_proposal.proposal_id, event.proposal_id)
    t.eq(called_proposal.round, 1)
    t.eq(called_proposal.dedup_key, conv_rounds.converge_proposal_base_dedup(event.dedup_key) .. "/loop/1")
    t.eq(called_proposal.convergence_question, event.narrowed_question)
    t.eq(called_proposal.findings_record, event.findings_record)
    t.eq(called_proposal.prior_round_digests, nil)
    t.eq(called_proposal.worktree, worktree)

    local request = find_raise(result.raises, "devloop_review_request")
    t.is_true(request ~= nil)
    t.eq(request.payload.proposal_id, event.proposal_id)
    t.eq(request.payload.dedup_key, called_proposal.dedup_key)

    local comment = find_raise(result.raises, "github-proxy.github_pr_comment_request")
    t.is_true(comment ~= nil)
    t.is_true(comment.payload.body:find('version="' .. review_version .. '"', 1, true) ~= nil)
    t.is_true(comment.payload.body:find('round="0"', 1, true) ~= nil)
  end,

  test_review_loop_evidence_continuation_budget_reconciles_without_another_proposal = function()
    local event = review_unresolved({
      dedup_key = "consensus:" .. devloop_base.pr_review_proposal_id("owner/repo", 7, reviewing().version, "def456") .. "/review/loop/1",
      round = 1,
      narrowed_question = "Which reviewed-head evidence resolves the gap now?",
      angle_digests = angles(1),
      findings_record = findings("second review finding"),
    })
    local _, _, review_version = devloop_base.parse_pr_review_proposal_id(event.proposal_id)
    local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
    local first_marker = conv_rounds.review_converge_round_marker(core,
      event.proposal_id,
      issue_proposal_id(),
      reviewing().version,
      "def456",
      sr_digest,
      0,
      "consensus:" .. event.proposal_id .. "/review",
      "First review boundary",
      angles(0),
      findings("first review finding")
    )
    prepare_review_context(event, { first_marker })

    local result = run_review_loop(event, opts("review-loop-evidence-continuation-budget"))
    local proposal = take_consensus_proposal()
    t.eq(result.exit_code, 0)
    -- Owner directive (#2725): the review continuation ROUND-BUDGET is a raw counter that
    -- must NEVER hand off a terminal review-reconcile; with two DISTINCT review rounds (not
    -- a true-stall) review convergence REDRIVES the next review round (consensus.proposal +
    -- converge comment) instead of dropping to blocked. No review-reconcile handoff.
    t.eq(#result.raises, 2)
    t.is_true(proposal ~= nil)
    t.eq(proposal.round, 2)
    local comment = find_raise(result.raises, "github-proxy.github_pr_comment_request")
    t.is_true(comment ~= nil)
    t.is_true(comment.payload.body:find('round="1"', 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_review_reconcile"), nil)
  end,

  test_review_loop_new_head_or_version_resets_resolvability_boundary = function()
    local current_head = "def456"
    local event = review_unresolved({
      dedup_key = "consensus:" .. devloop_base.pr_review_proposal_id("owner/repo", 7, reviewing().version, current_head) .. "/review",
      round = 0,
      narrowed_question = "Current review head question",
      angle_digests = angles(0),
      findings_record = findings("current review finding"),
    })
    local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
    local drift_version = reviewing().version .. "/drifted"
    local drift_head = "feedface"
    local drift_marker = conv_rounds.review_converge_round_marker(core,
      event.proposal_id,
      issue_proposal_id(),
      drift_version,
      drift_head,
      sr_digest,
      1,
      "consensus:" .. event.proposal_id .. "/review/loop/1",
      "Drifted review boundary",
      angles(1),
      findings("drifted review finding")
    )
    prepare_review_context(event, { drift_marker }, current_head)

    local result = run_review_loop(event, opts("review-loop-boundary-reset"))
    local proposal = take_consensus_proposal()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.is_true(proposal ~= nil)
    t.eq(proposal.dedup_key, conv_rounds.converge_proposal_base_dedup(event.dedup_key) .. "/loop/1")
    t.eq(proposal.findings_record, event.findings_record)
    t.eq(proposal.prior_round_digests, nil)
    t.eq(find_raise(result.raises, "devloop_review_reconcile"), nil)
  end,

  test_review_loop_essence_stall_reconciles_immediately = function()
    local event = review_unresolved({
      dedup_key = "consensus:" .. devloop_base.pr_review_proposal_id("owner/repo", 7, reviewing().version, "def456") .. "/review",
      round = 0,
      narrowed_question = "essence-stall + no review-resolving evidence remains",
      angle_digests = angles(0),
      findings_record = findings("no review-resolving evidence remains"),
      essence_stall = true,
    })
    local _, _, review_version = prepare_review_context(event)

    local result = run_review_loop(event, opts("review-loop-essence-stall"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.eq(find_raise(result.raises, "devloop_review_request"), nil)
    local comment = find_raise(result.raises, "github-proxy.github_pr_comment_request")
    t.is_true(comment ~= nil)
    t.is_true(comment.payload.body:find('essence_stall="true"', 1, true) ~= nil)
    local reconcile = find_raise(result.raises, "devloop_review_reconcile")
    t.is_true(reconcile ~= nil)
    t.eq(reconcile.payload.issue_version, review_version)
    t.eq(reconcile.payload.round, 0)
  end,
}
