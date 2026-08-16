local devloop_base = require("devloop.base")
local requests_review = require("devloop.requests.review")
local transition_version = require("contract.transition_version")
local h = require("tests.devloop_helpers")
local devloop_state = require("devloop.state")
local t = h.t
local core = h.core
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local action_label = h.action_label
local reason_label = h.reason_label
local has_value = h.has_value
local opts = h.opts
local source_ref = h.source_ref
local issue = h.issue
local reached = h.reached
local unresolved = h.unresolved
local ready = h.ready
local reviewing = h.reviewing
local review_reached = h.review_reached
local review_unresolved = h.review_unresolved
local fixing = h.fixing
local pr_link_marker_for_fix = h.pr_link_marker_for_fix
local review_meta_event = h.review_meta_event
local merge_ready = h.merge_ready
local run_observe = h.run_observe
local run_result = h.run_result
local run_loop = h.run_loop
local run_implement = h.run_implement
local run_observe_pr = h.run_observe_pr
local run_review_pr = h.run_review_pr
local run_review_result = h.run_review_result
local run_fix = h.run_fix
local run_review_loop = h.run_review_loop
local take_consensus_proposal = h.take_consensus_proposal
local run_review_meta = h.run_review_meta
local run_merge = h.run_merge
local json_string = h.json_string
local render_comment = h.render_comment
local find_causal_raise = h.find_causal_raise
local default_marker_version = h.default_marker_version
local mock_issue_state = h.mock_issue_state
local state_from_labels = h.state_from_labels
local with_default_state_marker = h.with_default_state_marker
local mock_issue_body = h.mock_issue_body
local mock_issue_result = h.mock_issue_result
local mock_issue_loop = h.mock_issue_loop
local mock_issue_implement = h.mock_issue_implement
local mock_issue_implement_raw = h.mock_issue_implement_raw
local mock_issue_reviewing = h.mock_issue_reviewing
local mock_issue_review = h.mock_issue_review
local mock_issue_fix = h.mock_issue_fix
local mock_issue_fix_for_event = h.mock_issue_fix_for_event
local mock_issue_review_meta = h.mock_issue_review_meta
local mock_issue_merge = h.mock_issue_merge
local merge_comments = h.merge_comments
local mock_pr_origin = h.mock_pr_origin
local mock_pr_merge = h.mock_pr_merge
local mock_pr_merge_rollup = h.mock_pr_merge_rollup
local mock_merging_comment = h.mock_merging_comment
local mock_pr_merge_command = h.mock_pr_merge_command
local has_call = h.has_call
local mock_issue_close = h.mock_issue_close
local merge_comments_with_merging = h.merge_comments_with_merging
local mock_pr_fix = h.mock_pr_fix
local mock_pr_origin_sequence = h.mock_pr_origin_sequence
local mock_pr_head = h.mock_pr_head
local mock_pr_diff = h.mock_pr_diff
local mock_branch_exists = h.mock_branch_exists
local mock_meta_codex = h.mock_meta_codex
local mock_setup_worktree = h.mock_setup_worktree
local deterministic_branch_for = h.deterministic_branch_for
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree = h.mock_existing_empty_implement_worktree
local mock_existing_empty_implement_worktree_reuse = h.mock_existing_empty_implement_worktree_reuse
local mock_existing_implement_branch = h.mock_existing_implement_branch
local mock_git_commit = h.mock_git_commit
local mock_git_push = h.mock_git_push
local mock_existing_devloop_worktree = h.mock_existing_devloop_worktree
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_existing_fix_worktree = h.mock_existing_fix_worktree
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_issue_view_failure = h.mock_issue_view_failure
local count_calls = h.count_calls
local find_raise = h.find_raise

return {
  test_review_loop_unresolved_under_budget_reraises_review_proposal = function()
    local event = review_unresolved()
    local impl_version = reviewing().version
    local origin_marker = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", impl_version, "dev")
    mock_bot_env()
    mock_pr_origin({ origin_marker }, "devloop-owner-repo-42-01HY", "def456")
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", impl_version),
    })

    local result = run_review_loop(event, opts("review-loop-under-budget"))
    local proposal = take_consensus_proposal()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.is_true(proposal.dedup_key:find("/loop/1", 1, true) ~= nil)
    t.is_nil(proposal.body:find("+return true", 1, true))
    t.is_true(find_raise(result.raises, "github-proxy.github_pr_comment_request").payload.body:find("fkst:github-devloop:review-converge-round:v1", 1, true) ~= nil)
    t.is_true(find_raise(result.raises, "github-proxy.github_pr_comment_request").payload.body:find('round="0"', 1, true) ~= nil)
  end,

  test_review_loop_long_reviewing_version_segment_applies = function()
    local full_version = reviewing().version
    for _ = 1, 6 do
      full_version = core.next_fix_version(full_version)
    end
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, full_version, "def456")
    local event = review_unresolved({
      proposal_id = proposal_id,
      dedup_key = "consensus:" .. proposal_id .. "/review",
    })
    local _, _, review_version = devloop_base.parse_pr_review_proposal_id(proposal_id)
    local origin_marker = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", full_version, "dev")
    t.is_true(transition_version.safe_version_segment(full_version) ~= full_version)
    t.eq(review_version, transition_version.safe_version_segment(full_version))

    mock_bot_env()
    mock_pr_origin({ origin_marker }, "devloop-owner-repo-42-01HY", "def456")
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", full_version),
    })

    local result = run_review_loop(event, opts("review-loop-long-version-apply"))
    local proposal = take_consensus_proposal()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.eq(proposal.proposal_id, proposal_id)
    t.is_true(find_raise(result.raises, "github-proxy.github_pr_comment_request").payload.body:find("fkst:github-devloop:review-converge-round:v1", 1, true) ~= nil)
    t.is_true(find_raise(result.raises, "github-proxy.github_pr_comment_request").payload.body:find('round="0"', 1, true) ~= nil)
  end,

  test_review_loop_long_reviewing_version_skips_after_issue_advanced = function()
    local full_version = reviewing().version
    for _ = 1, 6 do
      full_version = core.next_fix_version(full_version)
    end
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, full_version, "def456")
    local event = review_unresolved({
      proposal_id = proposal_id,
      dedup_key = "consensus:" .. proposal_id .. "/review",
    })
    local origin_marker = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", full_version, "dev")
    t.is_true(transition_version.safe_version_segment(full_version) ~= full_version)

    mock_bot_env()
    mock_pr_origin({ origin_marker }, "devloop-owner-repo-42-01HY", "def456")
    mock_issue_review({ "fkst-dev:fixing" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "fixing", core.next_fix_version(full_version)),
    })

    local result = run_review_loop(event, opts("review-loop-long-version-stale"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 0)
  end,

  test_review_loop_skips_when_issue_advanced_to_merge_ready = function()
    local full_version = reviewing().version
    for _ = 1, 6 do
      full_version = core.next_fix_version(full_version)
    end
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, full_version, "def456")
    local event = review_unresolved({
      proposal_id = proposal_id,
      dedup_key = "consensus:" .. proposal_id .. "/review",
    })
    local origin_marker = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", full_version, "dev")
    t.is_true(core.stage_rank("merge-ready") > core.stage_rank("reviewing"))

    mock_bot_env()
    mock_pr_origin({ origin_marker }, "devloop-owner-repo-42-01HY", "def456")
    mock_issue_review({ "fkst-dev:merge-ready" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "merge-ready", full_version),
    })

    local result = run_review_loop(event, opts("review-loop-advanced-merge-ready-stale"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 0)
  end,

  test_review_loop_retries_when_no_issue_state_marker_visible = function()
    local full_version = reviewing().version
    for _ = 1, 6 do
      full_version = core.next_fix_version(full_version)
    end
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, full_version, "def456")
    local event = review_unresolved({
      proposal_id = proposal_id,
      dedup_key = "consensus:" .. proposal_id .. "/review",
    })
    local origin_marker = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", full_version, "dev")

    mock_bot_env()
    mock_pr_origin({ origin_marker }, "devloop-owner-repo-42-01HY", "def456")
    mock_issue_review({ "fkst-dev:enabled" }, {})

    local result = run_review_loop(event, opts("review-loop-no-state-marker-pending"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 0)
  end,

  test_review_loop_skips_same_stage_different_review_version = function()
    local issue_version = reviewing().version
    for _ = 1, 6 do
      issue_version = core.next_fix_version(issue_version)
    end
    local event_version = core.next_fix_version(issue_version)
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, event_version, "def456")
    local event = review_unresolved({
      proposal_id = proposal_id,
      dedup_key = "consensus:" .. proposal_id .. "/review",
    })
    local _, _, review_version = devloop_base.parse_pr_review_proposal_id(proposal_id)
    local origin_marker = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", issue_version, "dev")
    t.is_true(transition_version.safe_version_segment(issue_version) ~= review_version)

    mock_bot_env()
    mock_pr_origin({ origin_marker }, "devloop-owner-repo-42-01HY", "def456")
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", issue_version),
    })

    local result = run_review_loop(event, opts("review-loop-reviewing-version-mismatch-stale"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 0)
  end,

  test_review_loop_long_reviewing_version_retries_before_reviewing_marker = function()
    local full_version = reviewing().version
    for _ = 1, 6 do
      full_version = core.next_fix_version(full_version)
    end
    local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, full_version, "def456")
    local event = review_unresolved({
      proposal_id = proposal_id,
      dedup_key = "consensus:" .. proposal_id .. "/review",
    })
    local origin_marker = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", full_version, "dev")
    t.is_true(transition_version.safe_version_segment(full_version) ~= full_version)

    mock_bot_env()
    mock_pr_origin({ origin_marker }, "devloop-owner-repo-42-01HY", "def456")
    mock_issue_review({ "fkst-dev:pr-open" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "pr-open", full_version),
    })

    local result = run_review_loop(event, opts("review-loop-long-version-pending"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 0)
  end,

  test_review_loop_old_unresolved_skips_after_issue_advanced_to_newer_fixing = function()
    local review_version = reviewing().version
    local event = review_unresolved()
    local fix_version = core.fix_version_from_review_version(review_version)
    local origin_marker = m_builders.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", review_version, "dev")
    mock_bot_env()
    mock_pr_origin({ origin_marker }, "devloop-owner-repo-42-01HY", "def456")
    mock_issue_review({ "fkst-dev:fixing" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "fixing", fix_version),
    })

    local result = run_review_loop(event, opts("review-loop-old-unresolved-after-fixing"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 0)
  end,

  test_review_meta_parse_failure_blocks_fail_closed = function()
    local event = review_meta_event()
    mock_issue_review_meta({ "fkst-dev:review-meta" }, {
      core.state_marker(event.proposal_id, "review-meta", event.version),
    })
    mock_meta_codex(nil)

    local result = run_review_meta(event, opts("review-meta-parse-failure"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:blocked")
    t.eq(find_raise(result.raises, "devloop_merge_ready"), nil)
    t.eq(count_calls("codex exec"), 1)
  end,

  test_review_meta_fix_and_block_actions = function()
    local event = review_meta_event()
    mock_issue_review_meta({ "fkst-dev:review-meta" }, {
      core.state_marker(event.proposal_id, "review-meta", event.version),
    })
    mock_meta_codex("fix", "Run another fix pass.")
    local fix_result = run_review_meta(event, opts("review-meta-fix"))
    t.eq(fix_result.exit_code, 0)
    t.eq(#fix_result.raises, 2)
    t.eq(find_raise(fix_result.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:fixing")
    t.eq(find_causal_raise(fix_result, "devloop_fixing").payload.schema, "github-devloop.fixing.v1")
    t.eq(find_causal_raise(fix_result, "devloop_fixing").payload.blocking_gap, "missing retry guard")

    mock_issue_review_meta({ "fkst-dev:review-meta" }, {
      core.state_marker(event.proposal_id, "review-meta", event.version),
    })
    mock_meta_codex("block", "Needs human intervention.")
    local block_result = run_review_meta(event, opts("review-meta-block"))
    t.eq(block_result.exit_code, 0)
    t.eq(#block_result.raises, 2)
    t.eq(find_raise(block_result.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:blocked")
  end,

  test_review_meta_marker_lag_retries_then_visible_marker_runs = function()
    local event = review_meta_event()
    mock_issue_review_meta({ "fkst-dev:enabled" }, {})

    local pending = run_review_meta(event, opts("review-meta-marker-lag"))
    t.eq(pending.exit_code, 1)
    t.eq(#pending.raises, 0)
    t.eq(count_calls("codex exec"), 0)

    mock_issue_review_meta({ "fkst-dev:review-meta" }, {
      core.state_marker(event.proposal_id, "review-meta", event.version),
    })
    mock_meta_codex("block", "The unresolved review needs human intervention.")

    local visible = run_review_meta(event, opts("review-meta-marker-visible"))
    t.eq(visible.exit_code, 0)
    t.eq(#visible.raises, 2)
    t.eq(find_raise(visible.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:blocked")
    t.eq(find_raise(visible.raises, "devloop_merge_ready"), nil)
  end,

  test_review_meta_fix_becomes_canonical_and_fix_uses_meta_feedback = function()
    local event = review_meta_event()
    local meta_exit_version = devloop_state.next_review_meta_action_version(event.version)
    mock_issue_review_meta({ "fkst-dev:review-meta" }, {
      core.state_marker(event.proposal_id, "review-meta", event.version),
    })
    mock_meta_codex("fix", "Run another fix pass.")

    local meta_result = run_review_meta(event, opts("review-meta-fix-canonical"))
    t.eq(meta_result.exit_code, 0)
    t.eq(#meta_result.raises, 2)
    local meta_comment = find_raise(meta_result.raises, "github-proxy.github_pr_comment_request").payload.body
    local current = devloop_state.current_state({
      core.state_marker(event.proposal_id, "review-meta", event.version),
      meta_comment,
    }, event.proposal_id)
    t.eq(current.state, "fixing")
    t.eq(current.version, meta_exit_version)
    local fix_event = find_causal_raise(meta_result, "devloop_fixing").payload
    t.eq(fix_event.version, meta_exit_version)
    t.eq(fix_event.blocking_gap, "missing retry guard")

    local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
    local recomputed_branch = devloop_base.implement_branch("owner/repo", "42", meta_exit_version)
    t.eq(branch ~= recomputed_branch, true)
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_fix_for_event(fix_event, { "fkst-dev:fixing" }, {
      meta_comment,
    }, branch, event.version)
    mock_pr_fix({ origin_marker }, branch, "def456")
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', { stdout = "/tmp/fkst-packages-test/github-devloop/runtime", stderr = "", exit_code = 0 })
    mock_existing_fix_worktree(branch, "def456")
    mock_implement_codex(0, "fixed review-meta feedback")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("feedface", branch)
    mock_write_env("1")
    mock_issue_fix_for_event(fix_event, { "fkst-dev:fixing" }, {
      meta_comment,
    }, branch, event.version)
    mock_git_push(branch)
    mock_pr_fix({ origin_marker }, branch, "feedface")

    local fix_result = run_fix(fix_event, opts("fix-from-review-meta-feedback", { FKST_GITHUB_WRITE = "1" }))
    t.eq(fix_result.exit_code, 0)
    t.eq(#fix_result.raises, 2)
    t.eq(find_raise(fix_result.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:reviewing")
    t.eq(find_causal_raise(fix_result, "devloop_reviewing").payload.version, core.next_fix_version(meta_exit_version))
  end,

}
