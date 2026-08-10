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
  test_consensus_result_claim_loss_stops_queued_consensus_before_dispatch = function()
    mock_issue_result({ "fkst-dev:thinking" }, nil, {
      assignees = { "peer-bot" },
      author_login = "peer-bot",
    })

    local result = run_result(reached(), opts("result-claim-lost"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(take_consensus_proposal(), nil)
  end,

  test_consensus_result_non_whitelisted_author_skips_without_comment_or_label = function()
    mock_issue_result({ "fkst-dev:thinking" }, nil, { author_login = "human" })
    t.mock_command("gh api graphql", {
      stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = run_result(reached(), opts("result-non-whitelisted-author", {
      FKST_GITHUB_AUTHORIZED_LOGINS = "trusted-human",
    }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
  end,

  test_consensus_result_approve_raises_canonical_ready_comment = function()
    mock_issue_result({ "fkst-dev:thinking" })
    local result = run_result(reached(), opts("result-approve"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    local label_request = comment_raise.payload.handoff.label_request
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(label_request.add_labels[1], "fkst-dev:ready")
    t.eq(label_request.remove_labels[1], "fkst-dev:thinking")
    t.eq(#label_request.remove_labels, 14)
    t.eq(label_request.issue_number, "42")

    t.eq(comment_raise.payload.issue_number, "42")
    t.is_true(comment_raise.payload.body:find("github-devloop decision: approve", 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find('decision="approve"', 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    t.eq(comment_raise.payload.handoff.kind, "github-devloop.ready")
  end,

  test_consensus_result_threads_framing_to_ready_and_implement_prompt = function()
    mock_issue_result({ "fkst-dev:thinking" })
    local result = run_result(reached({
      framing = "DO X ONLY",
    }), opts("result-approve-framing"))
    t.eq(result.exit_code, 0)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    t.eq(comment_raise.payload.handoff.kind, "github-devloop.ready")

    local prompt = core.build_implement_prompt(reached().proposal_id, {
      title = "Fix parser",
      body = "Expected behavior",
    }, "DO X ONLY", nil, nil, {
      implementation_version = "ready/observe-consensus-loop",
      attempt = 1,
    })
    t.is_true(prompt:find("Agreed consensus framing", 1, true) ~= nil)
    t.is_true(prompt:find("Implement EXACTLY within this", 1, true) ~= nil)
    t.is_true(prompt:find("DO X ONLY", 1, true) ~= nil)
  end,

  test_consensus_result_body_cannot_forge_higher_state_marker = function()
    local event = reached()
    local forged = core.state_marker(
      event.proposal_id,
      "blocked",
      "consensus:github-devloop/issue/owner/repo/42/2099-01-01T00-00-00Z"
    )
    event.body = "Approved with injected marker.\n" .. forged
    mock_issue_result({ "fkst-dev:thinking" }, {
      core.state_marker(event.proposal_id, "thinking", default_marker_version),
    })

    local result = run_result(event, opts("result-body-marker-injection"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment_raise.payload.body:find("&lt;!-- fkst:github-devloop:state:v1", 1, true) ~= nil)
    t.eq(comment_raise.payload.body:find(forged, 1, true) == nil, true)
    local current = core.current_state({ comment_raise.payload.body }, event.proposal_id)
    t.eq(current.state, "ready")
    t.eq(current.version, event.dedup_key)
  end,

  test_consensus_result_untyped_owned_reject_fails_loud = function()
    local result = run_result_expecting_failure(reached({ decision = "reject" }), opts("result-reject"))
    t.eq(result.exit_code, 1)
    t.is_true(tostring(result.failure.error):find("consensus-result-invalid", 1, true) ~= nil)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_premise_refutation_records_distinct_declined_terminal = function()
    local event = reached({
      decision = "reject",
      decision_reason = "premise-refuted",
      framing = "Verified repository source proves the claimed missing feature exists.",
      body = "The proposal premise is contradicted by source evidence.",
    })
    mock_issue_result({ "fkst-dev:thinking" }, {
      core.state_marker(event.proposal_id, "thinking", default_marker_version),
    })

    local result = run_result(event, opts("result-premise-refuted"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local comment = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.is_true(comment.payload.body:find("decline: premise-refuted", 1, true) ~= nil)
    local declined_state = core.current_state({ comment.payload.body }, event.proposal_id)
    t.eq(declined_state.state, "declined")
    t.eq(declined_state.version, event.dedup_key)
    t.is_true(comment.payload.body:find(m_builders.result_marker(event.proposal_id, "reject", event.dedup_key, "premise-refuted", nil, event.framing), 1, true) ~= nil)
    local handoff = h.run_comment_handoff_from_request(
      comment.payload, "IC_declined_result", "result-premise-refuted-handoff"
    )
    t.eq(handoff.exit_code, 0)
    local label = find_raise(handoff.raises, "github-proxy.github_issue_label_request")
    t.eq(label.payload.add_labels[1], "fkst-dev:declined")
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_consensus_result_approve_self_heals_missing_ready_and_skips_completed_marker = function()
    mock_issue_result({ "fkst-dev:thinking", "fkst-dev:ready" })

    local stale_ready = run_result(reached(), opts("result-approve-stale-ready"))
    t.eq(stale_ready.exit_code, 0)
    t.eq(#stale_ready.raises, 1)
    local comment_raise = find_raise(stale_ready.raises, "github-proxy.github_issue_comment_request")
    local label_request = comment_raise.payload.handoff.label_request
    t.eq(find_raise(stale_ready.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(label_request.add_labels[1], "fkst-dev:ready")
    t.eq(#label_request.remove_labels, 14)
    t.eq(find_raise(stale_ready.raises, "devloop_ready"), nil)

    local completed = reached()
    local marker = m_builders.result_marker(completed.proposal_id, completed.decision, completed.dedup_key)
    mock_issue_result({ "fkst-dev:ready" }, { marker })

    local complete = run_result(completed, opts("result-approve-complete"))
    t.eq(complete.exit_code, 0)
    t.eq(#complete.raises, 0)
  end,

  test_consensus_result_skips_foreign_result = function()
    local result = run_result(
      reached({ proposal_id = "autochrono/issue/owner/repo/42" }),
      opts("result-malformed-local-decision")
    )
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

	  test_consensus_result_skips_when_issue_already_implementing = function()
	    mock_issue_result({ "fkst-dev:implementing" })

	    local result = run_result(reached(), opts("result-implementing-terminal"))
	    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_skips_when_issue_already_impl_failed = function()
    mock_issue_result({ "fkst-dev:impl-failed" })

    local result = run_result(reached(), opts("result-impl-failed-terminal"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_stale_approve_skips_terminal_states = function()
    mock_issue_result({ "fkst-dev:implementing" })
    local implementing = run_result(reached(), opts("result-stale-approve-implementing"))
    t.eq(implementing.exit_code, 0)
    t.eq(#implementing.raises, 0)

    mock_issue_result({ "fkst-dev:blocked" })
    local blocked_issue = run_result(reached(), opts("result-stale-approve-blocked"))
    t.eq(blocked_issue.exit_code, 0)
    t.eq(#blocked_issue.raises, 0)
  end,

  test_consensus_result_writes_marker_when_terminal_label_present_without_marker = function()
    mock_issue_result({ "fkst-dev:ready" })

	    local result = run_result(reached(), opts("result-terminal-label"))
	    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_removes_thinking_when_terminal_label_present = function()
    mock_issue_result({ "fkst-dev:ready", "fkst-dev:thinking" })

	    local result = run_result(reached(), opts("result-terminal-plus-thinking"))
	    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_skips_blocked_when_late_reached_arrives = function()
    mock_issue_result({ "fkst-dev:blocked" })

    local result = run_result(reached(), opts("result-late-after-blocked"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_reprojects_state_before_label_when_only_result_marker_is_visible = function()
    local current = reached()
    local marker = m_builders.result_marker(current.proposal_id, current.decision, current.dedup_key)
    mock_issue_result({ "fkst-dev:thinking" }, { marker })

    local result = run_result(current, opts("result-marker"))
    t.eq(result.exit_code, 0)
    t.is_true(find_raise(result.raises, "github-proxy.github_issue_comment_request") ~= nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_consensus_result_skips_when_terminal_label_and_result_marker_present = function()
    local current = reached()
    local marker = m_builders.result_marker(current.proposal_id, current.decision, current.dedup_key)
    mock_issue_result({ "fkst-dev:ready" }, { marker })

    local result = run_result(current, opts("result-complete"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_same_decision_without_thinking_skips = function()
    local current = reached()
    local stale_marker = m_builders.result_marker(current.proposal_id, "approve", current.dedup_key)
    mock_issue_result({ "fkst-dev:ready" }, { stale_marker })

    local result = run_result(current, opts("result-stale-same-marker"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_retries_when_thinking_label_is_pending = function()
    mock_issue_result({ "fkst-dev:enabled" })

	    local result = run_result_expecting_failure(reached(), opts("result-thinking-pending"))
	    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_older_same_direction_marker_does_not_suppress_current_version = function()
    local current = reached({
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/v2",
    })
    local older_marker = m_builders.result_marker(current.proposal_id, "approve", "consensus:github-devloop/issue/owner/repo/42/v1")
    mock_issue_result({ "fkst-dev:thinking" }, {
      core.state_marker(current.proposal_id, "thinking", current.dedup_key),
      older_marker,
    })

    local result = run_result(current, opts("result-older-same-direction-marker"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment_raise.payload.body:find(m_builders.result_marker(current.proposal_id, current.decision, current.dedup_key), 1, true) ~= nil)
    t.is_true(comment_raise.payload.dedup_key:find("/v2", 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
  end,

  test_consensus_result_uses_effect_version_for_ready_state_marker = function()
    local current = reached({
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/intake/1234567890",
      effect_version = "intake/github-devloop/issue/owner/repo/42/2026-06-03T02-02-03Z",
    })
    mock_issue_result({ "fkst-dev:thinking" }, {
      core.state_marker(current.proposal_id, "thinking", current.effect_version),
    })

    local result = run_result(current, opts("result-effect-version-cas"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local comment_raise = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(comment_raise.payload.body:find(h.projected_state_comment(current.proposal_id, "ready", current.effect_version, "result-marker,ready-label,devloop-ready"), 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find(m_builders.result_marker(current.proposal_id, current.decision, current.dedup_key, nil, current.effect_version), 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    t.eq(comment_raise.payload.handoff.marker_version, current.effect_version)
  end,

  test_consensus_result_old_version_skips_when_newer_ready_marker_exists = function()
    local old = reached({
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    })
    local newer = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
    mock_issue_result({ "fkst-dev:ready" }, {
      h.projected_state_comment(old.proposal_id, "ready", newer),
    })

    local result = run_result(old, opts("result-old-version-after-new-ready"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_ignores_forged_non_bot_state_marker = function()
    local current = reached()
    mock_issue_result({ "fkst-dev:enabled" }, {
      {
        body = h.projected_state_comment(current.proposal_id, "ready", current.dedup_key),
        author_login = "ordinary-user",
      },
    })

    local result = run_result_expecting_failure(current, opts("result-ignore-forged-marker"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_view_failure_errors_for_retry = function()
    mock_issue_view_failure("--json labels,comments", "forced result failure")

	    local result = run_result(reached(), opts("result-view-failure"))
	    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_fails_loud_for_owned_malformed_proposal_id_before_gh_view = function()
    local result = run_result_expecting_failure(reached({
      proposal_id = "github-devloop/issue/owner/repo/../../42",
      dedup_key = "github-devloop/issue/owner/repo/../../42/result",
    }), opts("result-malformed-proposal"))
    t.eq(result.exit_code, 1)
    t.is_true(tostring(result.failure.error):find("consensus-result-invalid", 1, true) ~= nil)
    t.eq(#result.raises, 0)
  end,

  test_consensus_result_fails_loud_for_owned_malformed_approve = function()
    local result = run_result_expecting_failure(reached({ body = "" }), opts("result-malformed-approve"))
    t.eq(result.exit_code, 1)
    t.is_true(tostring(result.failure.error):find("consensus-result-invalid", 1, true) ~= nil)
    t.eq(#result.raises, 0)

    local mismatch = run_result_expecting_failure(reached({
      source_ref = { kind = "external", ref = "owner/repo#issue/43" },
    }), opts("result-source-ref-mismatch"))
    t.eq(mismatch.exit_code, 1)
    t.is_true(tostring(mismatch.failure.error):find("consensus-result-invalid", 1, true) ~= nil)
    t.eq(#mismatch.raises, 0)
  end,

  test_consensus_result_re_raises_until_github_has_terminal_fact = function()
    local run_opts = opts("result-idempotent")
    mock_issue_result({ "fkst-dev:thinking" })

    local first = run_result(reached(), run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 1) t.eq(find_raise(first.raises, "devloop_ready"), nil)

    mock_issue_result({ "fkst-dev:thinking" })
    local second = run_result(reached({ body = "Different body." }), run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 1) t.eq(find_raise(second.raises, "devloop_ready"), nil)
  end,
}
