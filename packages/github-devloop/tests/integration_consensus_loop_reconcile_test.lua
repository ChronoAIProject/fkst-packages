local fixture = require("tests.integration_observe_consensus_helpers")
local convergence_shared = fixture.convergence_shared
local h = fixture.h
local conv_rounds = fixture.conv_rounds
local conv_reconcile = fixture.conv_reconcile
local m_builders = fixture.m_builders
local devloop_base = fixture.devloop_base
local t = fixture.t
local core = fixture.core
local action_label = fixture.action_label
local reason_label = fixture.reason_label
local has_value = fixture.has_value
local opts = fixture.opts
local source_ref = fixture.source_ref
local issue = fixture.issue
local reached = fixture.reached
local unresolved = fixture.unresolved
local reconcile = fixture.reconcile
local ready = fixture.ready
local reviewing = fixture.reviewing
local review_reached = fixture.review_reached
local review_unresolved = fixture.review_unresolved
local fixing = fixture.fixing
local pr_link_marker_for_fix = fixture.pr_link_marker_for_fix
local review_meta_event = fixture.review_meta_event
local merge_ready = fixture.merge_ready
local run_observe = fixture.run_observe
local run_result = fixture.run_result
local run_result_expecting_failure = fixture.run_result_expecting_failure
local run_loop = fixture.run_loop
local run_reconcile = fixture.run_reconcile
local run_implement = fixture.run_implement
local run_observe_pr = fixture.run_observe_pr
local run_review_pr = fixture.run_review_pr
local run_review_result = fixture.run_review_result
local run_fix = fixture.run_fix
local set_pr_phase_comments = fixture.set_pr_phase_comments
local run_review_meta = fixture.run_review_meta
local run_merge = fixture.run_merge
local json_string = fixture.json_string
local render_comment = fixture.render_comment
local default_marker_version = fixture.default_marker_version
local mock_issue_state = fixture.mock_issue_state
local state_from_labels = fixture.state_from_labels
local with_default_state_marker = fixture.with_default_state_marker
local mock_issue_body = fixture.mock_issue_body
local mock_issue_result = fixture.mock_issue_result
local mock_issue_loop = fixture.mock_issue_loop
local mock_issue_reconcile = fixture.mock_issue_reconcile
local mock_issue_implement = fixture.mock_issue_implement
local mock_issue_implement_raw = fixture.mock_issue_implement_raw
local mock_issue_reviewing = fixture.mock_issue_reviewing
local mock_issue_review = fixture.mock_issue_review
local mock_issue_fix = fixture.mock_issue_fix
local mock_issue_fix_for_event = fixture.mock_issue_fix_for_event
local mock_issue_review_meta = fixture.mock_issue_review_meta
local mock_issue_merge = fixture.mock_issue_merge
local merge_comments = fixture.merge_comments
local mock_pr_origin = fixture.mock_pr_origin
local mock_pr_merge = fixture.mock_pr_merge
local mock_pr_merge_rollup = fixture.mock_pr_merge_rollup
local mock_merging_comment = fixture.mock_merging_comment
local mock_pr_merge_command = fixture.mock_pr_merge_command
local has_call = fixture.has_call
local mock_issue_close = fixture.mock_issue_close
local merge_comments_with_merging = fixture.merge_comments_with_merging
local mock_pr_fix = fixture.mock_pr_fix
local mock_pr_origin_sequence = fixture.mock_pr_origin_sequence
local mock_pr_head = fixture.mock_pr_head
local mock_pr_diff = fixture.mock_pr_diff
local mock_branch_exists = fixture.mock_branch_exists
local mock_setup_worktree = fixture.mock_setup_worktree
local deterministic_branch_for = fixture.deterministic_branch_for
local mock_fresh_implement_worktree = fixture.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree = fixture.mock_existing_empty_implement_worktree
local mock_existing_empty_implement_worktree_reuse = fixture.mock_existing_empty_implement_worktree_reuse
local mock_existing_implement_branch = fixture.mock_existing_implement_branch
local mock_git_commit = fixture.mock_git_commit
local mock_git_push = fixture.mock_git_push
local mock_existing_devloop_worktree = fixture.mock_existing_devloop_worktree
local mock_implement_codex = fixture.mock_implement_codex
local mock_git_status = fixture.mock_git_status
local mock_write_env = fixture.mock_write_env
local mock_bot_env = fixture.mock_bot_env
local mock_issue_view_failure = fixture.mock_issue_view_failure
local count_calls = fixture.count_calls
local find_raise = fixture.find_raise
local find_causal_raise = fixture.find_causal_raise
local take_consensus_proposal = fixture.take_consensus_proposal

return {
  test_loop_unresolved_records_converge_round_and_reraises_proposal = function()
    mock_issue_loop({ "fkst-dev:thinking" })

    local event = unresolved({
      narrowed_question = "Can the issue be implemented as-is?",
      angle_digests = {
        { angle = "minimal", verdict = "abstain", digest = "needs-scope" },
      },
    })
    local result = run_loop(event, opts("loop-converge-round"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    local proposal = take_consensus_proposal()
    t.eq(proposal.schema, "consensus.proposal.v1")
    t.eq(proposal.proposal_id, "github-devloop/issue/owner/repo/42")
    t.is_true(#proposal.body < 256)
    t.is_nil(proposal.body:find("Body from GitHub", 1, true))
    t.is_true(proposal.content_fetch:find("runtime-cache:", 1, true) == 1)
    t.is_nil(proposal.content_fetch:find("gh issue", 1, true))
    t.eq(proposal.dedup_key, "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/loop/1")
    t.eq(proposal.convergence_question, event.narrowed_question)
    t.eq(proposal.source_ref.ref, "owner/repo#issue/42")
    t.eq(proposal.worktree, ".")
    t.is_true(find_raise(result.raises, "devloop_consensus_request") ~= nil)

    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request").payload
    t.is_true(comment.body:find("fkst:github-devloop:converge-round:v1", 1, true) ~= nil)
    t.is_true(comment.body:find('round="0"', 1, true) ~= nil)
  end,

  test_loop_non_whitelisted_author_converge_skips_without_comment_or_consensus = function()
    mock_issue_loop({ "fkst-dev:thinking" }, nil, { author_login = "human" })

    local result = run_loop(unresolved(), opts("loop-non-whitelisted-author", {
      FKST_GITHUB_AUTHORIZED_LOGINS = "trusted-human",
    }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(find_raise(result.raises, "devloop_consensus_request"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
  end,

  test_loop_visible_over_budget_lineage_handoffs_reconcile_before_new_result = function()
    local base_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local event = unresolved({
      dedup_key = base_version .. "/loop/3",
      round = 3,
      narrowed_question = "Same framing",
      angle_digests = {
        { angle = "minimal", verdict = "abstain", digest = "same" },
      },
    })
    local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
    mock_issue_loop({ "fkst-dev:thinking" }, {
      conv_rounds.converge_round_marker(event.proposal_id, base_version, sr_digest, 1, base_version .. "/loop/1", event.narrowed_question, event.angle_digests),
      conv_rounds.converge_round_marker(event.proposal_id, base_version, sr_digest, 2, base_version .. "/loop/2", event.narrowed_question, event.angle_digests),
    })

    local result = run_loop(event, opts("loop-true-stall"))
    t.eq(result.exit_code, 0)
    -- Owner directive (#2725): the raw continuation ROUND-BUDGET is no longer terminal,
    -- but three identical convergence rounds are a genuine TRUE-STALL
    -- (no-semantic-progress) which correctly REMAINS terminal. With the round-3 current
    -- round appended to the visible round-1/round-2 lineage, terminal_cause is now the
    -- true-stall at round 3, not the retired budget-exhaustion at round 2.
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github-proxy.github_issue_comment_request")
    t.eq(find_raise(result.raises, "devloop_reconcile"), nil)
    t.eq(result.raises[1].payload.handoff.kind, "github-devloop.reconcile")
    t.eq(result.raises[1].payload.handoff.proposal_id, event.proposal_id)
    t.eq(result.raises[1].payload.handoff.round, 3)
    t.eq(result.raises[1].payload.handoff.base_version, base_version)
    t.eq(result.raises[1].payload.handoff.terminal_cause, "no-semantic-progress")
    t.eq(result.raises[1].payload.handoff.source_ref.ref, "owner/repo#issue/42")
  end,

  test_loop_second_resolvable_findings_handoff_reconcile_even_when_question_varies = function()
    local base_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local function varying_digest(round)
      return {
        { angle = "minimal", verdict = "abstain", digest = "digest-" .. tostring(round) },
      }
    end
    local event = unresolved({
      dedup_key = base_version .. "/loop/1",
      round = 1,
      narrowed_question = "Question 1",
      angle_digests = varying_digest(1),
      findings_record = "open:\nsecond resolvable finding",
    })
    local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
    mock_issue_loop({ "fkst-dev:thinking" }, {
      conv_rounds.converge_round_marker(event.proposal_id, base_version, sr_digest, 0, base_version, "Question 0", varying_digest(0), "open:\nfirst resolvable finding"),
    })

    local result = run_loop(event, opts("loop-second-resolvable-findings"))
    t.eq(result.exit_code, 0)
    -- Owner directive (#2725): the continuation round-budget is non-terminal; with two
    -- DISTINCT resolvable rounds (not a true-stall), convergence REDRIVES the next round
    -- instead of handing off a terminal reconcile.
    t.eq(#result.raises, 2)
    local proposal = take_consensus_proposal()
    t.is_true(proposal ~= nil)
    t.eq(proposal.round, 2)
    t.is_true(find_raise(result.raises, "devloop_consensus_request") ~= nil)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment ~= nil)
    t.is_true(comment.payload.body:find('round="1"', 1, true) ~= nil)
    t.is_nil(comment.payload.handoff)
    t.eq(find_raise(result.raises, "devloop_reconcile"), nil)
  end,

  test_loop_duplicate_round_is_non_terminal_skip = function()
    local event = unresolved({ round = 1 })
    local base_version = conv_rounds.converge_base_version(event.dedup_key)
    local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
    mock_issue_loop({ "fkst-dev:thinking" }, {
      conv_rounds.converge_round_marker(event.proposal_id, base_version, sr_digest, 1, event.dedup_key, nil, nil),
    })

    local result = run_loop(event, opts("loop-duplicate-converge-round"))
    t.eq(result.exit_code, 0)
    -- Owner directive (#2725): the continuation round-budget is non-terminal, so a
    -- duplicate converge round already at the visible lineage head no longer trips a
    -- terminal reconcile handoff; it is a plain idempotent skip (never drops to blocked).
    t.eq(#result.raises, 0)
  end,

  test_loop_stale_lower_round_is_non_terminal_skip = function()
    local base_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local event = unresolved({
      dedup_key = base_version .. "/loop/2",
      round = 2,
      narrowed_question = "Same framing",
      angle_digests = {
        { angle = "minimal", verdict = "abstain", digest = "same" },
      },
    })
    local sr_digest = convergence_shared.source_ref_digest(event.source_ref)
    mock_issue_loop({ "fkst-dev:thinking" }, {
      conv_rounds.converge_round_marker(event.proposal_id, base_version, sr_digest, 4, base_version .. "/loop/4", event.narrowed_question, event.angle_digests),
    })

    local result = run_loop(event, opts("loop-stale-lower-round"))
    t.eq(result.exit_code, 0)
    -- Owner directive (#2725): the round-budget is non-terminal; a stale lower incoming
    -- round behind a newer visible lineage head is a plain idempotent skip, not a
    -- terminal reconcile handoff (never drops to blocked).
    t.eq(#result.raises, 0)
  end,

  test_loop_skips_foreign_proposal = function()
    local result = run_loop(unresolved({ proposal_id = "autochrono/issue/owner/repo/42" }), opts("loop-foreign"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_loop_skips_already_terminal_issue = function()
    mock_issue_loop({ "fkst-dev:ready" })

    local result = run_loop(unresolved(), opts("loop-terminal"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_loop_skips_already_implementing_issue = function()
    mock_issue_loop({ "fkst-dev:implementing" })

    local result = run_loop(unresolved(), opts("loop-implementing-terminal"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_loop_skips_impl_failed_issue_by_label = function()
    mock_issue_loop({ "fkst-dev:impl-failed" })

    local result = run_loop(unresolved(), opts("loop-impl-failed-label"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_loop_retries_until_state_label_is_visible = function()
    mock_issue_loop({ "fkst-dev:enabled" })

    local pending = run_loop(unresolved(), opts("loop-state-label-pending"))
    t.eq(pending.exit_code, 1)
    t.eq(#pending.raises, 0)

    mock_issue_loop({ "fkst-dev:ready" })
    local ready = run_loop(unresolved(), opts("loop-state-label-ready"))
    t.eq(ready.exit_code, 0)
    t.eq(#ready.raises, 0)

    mock_issue_loop({ "fkst-dev:thinking" })
    local thinking = run_loop(unresolved(), opts("loop-state-label-thinking"))
    t.eq(thinking.exit_code, 0)
    t.eq(#thinking.raises, 2)
    t.is_true(take_consensus_proposal() ~= nil)
    t.is_true(find_raise(thinking.raises, "devloop_consensus_request") ~= nil)
    t.is_true(find_raise(thinking.raises, "github-proxy.github_issue_comment_request") ~= nil)
  end,

  test_loop_issue_view_failure_errors_for_retry = function()
    mock_issue_view_failure("--json title,updatedAt,labels,comments,state", "forced loop failure")

    local result = run_loop(unresolved(), opts("loop-view-failure"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
  end,

  test_reconcile_drop_blocks_thinking_issue = function()
    local event = reconcile()
    mock_issue_reconcile({ "fkst-dev:thinking" })

    local result = run_reconcile(event, opts("reconcile-drop"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request").payload
    local label = find_raise(result.raises, "github-proxy.github_issue_label_request").payload
    local version = conv_reconcile.reconcile_terminal_state_version(default_marker_version, event.round)
    t.is_true(comment.body:find("github-devloop reconcile action: drop", 1, true) ~= nil)
    t.is_true(comment.body:find("no-semantic-progress-after-3-rounds", 1, true) ~= nil)
    t.is_true(comment.body:find(core.state_marker(event.proposal_id, "blocked", version), 1, true) ~= nil)
    t.is_true(comment.body:find(conv_reconcile.reconcile_marker(event.proposal_id, event.base_version, event.round, "drop", event.terminal_cause), 1, true) ~= nil)
    t.eq(label.add_labels[1], "fkst-dev:blocked")
    t.eq(label.remove_labels[1], "fkst-dev:thinking")
    t.eq(count_calls("codex exec"), 0)
  end,

  test_reconcile_visible_marker_is_idempotent = function()
    local event = reconcile()
    local state_version = "github-devloop/issue/owner/repo/42/2026-06-14T05-22-55Z/intake/1287859418"
    mock_issue_reconcile({ "fkst-dev:blocked" }, {
      core.build_reconcile_comment_request("owner/repo", "42", event, "drop", "already done", conv_reconcile.reconcile_terminal_state_version(state_version, event.round)).body,
    })

    local result = run_reconcile(event, opts("reconcile-idempotent"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_reconcile_version_cas_skips_newer_terminal = function()
    local event = reconcile()
    mock_issue_reconcile({ "fkst-dev:blocked" }, {
      core.state_marker(event.proposal_id, "blocked", event.base_version .. "/loop/4"),
    })

    local result = run_reconcile(event, opts("reconcile-newer-terminal"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_reconcile_requires_visible_thinking_marker = function()
    mock_issue_reconcile({ "fkst-dev:enabled" })

    local result = run_reconcile(reconcile(), opts("reconcile-pending-thinking"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
  end
}
