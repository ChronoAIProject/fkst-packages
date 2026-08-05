local entity_lib = require("devloop.entity")
local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local transition_version = require("contract.transition_version")
local h = require("tests.devloop_helpers")
local autonomy_ledger = require("devloop.autonomy_ledger")
local payloads_builders = require("devloop.payloads.builders")
local m_facts = require("devloop.markers.facts")
local m_builders = require("devloop.markers.builders")
local t = h.t
local core = h.core
local action_label = h.action_label
local reason_label = h.reason_label
local has_value = h.has_value
local opts = h.opts
local source_ref = h.source_ref
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
local run_result = h.run_result
local run_loop = h.run_loop
local run_implement = h.run_implement
local run_observe_pr = h.run_observe_pr
local run_review_pr = h.run_review_pr
local run_review_result = h.run_review_result
local run_fix = h.run_fix
local run_review_loop = h.run_review_loop
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
local pr_native_comments = h.pr_native_comments
local mock_pr_origin = h.mock_pr_origin
local mock_pr_merge = h.mock_pr_merge
local mock_pr_merge_rollup = h.mock_pr_merge_rollup
local mock_merging_comment = h.mock_merging_comment
local mock_pr_merge_command = h.mock_pr_merge_command
local mock_pr_ready = h.mock_pr_ready
local has_call = h.has_call
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
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_issue_view_failure = h.mock_issue_view_failure
local count_calls = h.count_calls
local find_raise = h.find_raise

local function pr_native_review_reached(extra)
  local version = "pr-native-version"
  local proposal_id = devloop_base.pr_review_proposal_id("owner/repo", 7, version, "def456")
  local value = {
    schema = "consensus.consensus_reached.v1",
    proposal_id = proposal_id,
    decision = "approve",
    body = "Review consensus approves the PR-native diff.",
    dedup_key = "consensus:" .. proposal_id .. "/review",
    source_ref = h.pr_source_ref(),
  }
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function pr_native_merge_ready(extra)
  local event = pr_native_review_reached()
  local value = payloads_builders.build_devloop_merge_ready_payload(entity_lib.pr_proposal_id("owner/repo", 7),
    7,
    "pr-native-version",
    {
      review_proposal_id = event.proposal_id,
      review_dedup_key = event.dedup_key,
      reviewed_head_sha = "def456",
    },
    h.pr_source_ref()
  )
  for key, field in pairs(extra or {}) do
    value[key] = field
  end
  return value
end

local function mock_base_head_for_stale_mergeability() t.mock_command("git fetch origin dev", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git rev-parse --verify 'refs/remotes/origin/dev^{commit}'", { stdout = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", stderr = "", exit_code = 0 })
  t.mock_command("git merge-base --is-ancestor aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa def456", { stdout = "", stderr = "", exit_code = 1 }) end

local function mock_failing_required_check_runs()
  t.mock_command("gh api 'repos/owner/repo/commits/def456/check-runs'", {
    stdout = '{"total_count":1,"check_runs":[{"name":"test","status":"completed","conclusion":"failure","head_sha":"def456"}]}\n',
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_merge_pr_head_advanced_after_recheck_reenters_reviewing_for_current_head = function()
    local event = merge_ready()
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_pr_merge({ origin_marker })
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_write_env("1")
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "feedface")
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "feedface")

    local result = run_merge(event, opts("merge-head-advanced-after-recheck", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.eq(count_calls("gh pr merge"), 0)
    local label_raise = find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.eq(label_raise.payload.add_labels[1], "fkst-dev:reviewing")
    t.is_true(has_value(label_raise.payload.remove_labels, "fkst-dev:merge-ready"))
    local reviewing_raise = find_causal_raise(result, "devloop_reviewing")
    t.eq(reviewing_raise.payload.schema, "github-devloop.reviewing.v1")
    t.eq(reviewing_raise.payload.version, event.version .. "/review-loop/1")
    t.eq(reviewing_raise.payload.pr_number, event.pr_number)
    local review_repo, review_pr, review_version, review_head = devloop_base.parse_pr_review_proposal_id(
      devloop_base.pr_review_proposal_id("owner/repo", reviewing_raise.payload.pr_number, reviewing_raise.payload.version, "feedface")
    )
    t.eq(review_repo, devloop_base.safe_pr_review_repo_segment("owner/repo"))
    t.eq(review_pr, tostring(event.pr_number))
    t.eq(review_version, transition_version.safe_version_segment(reviewing_raise.payload.version))
    t.eq(review_head, "feedface")
    local comment_body = find_raise(result.raises, "github-proxy.github_pr_comment_request").payload.body
    t.is_true(comment_body:find('state="reviewing"', 1, true) ~= nil)
    t.is_true(comment_body:find('version="' .. event.version .. "/review-loop/1" .. '"', 1, true) ~= nil)
    t.eq(find_raise(result.raises, "devloop_fixing"), nil)
    t.eq(count_calls("gh issue close"), 0)
  end,

  test_merge_pr_head_advanced_reentry_is_idempotent_for_current_head = function()
    local event = merge_ready()
    local review_version = event.version .. "/review-loop/1"
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    local comments = merge_comments(event)
    table.insert(comments, core.state_marker(event.proposal_id, "reviewing", review_version))
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:reviewing" }, comments)
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "feedface")

    local result = run_merge(event, opts("merge-head-advanced-reviewing-idempotent", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr merge"), 0)
    t.eq(count_calls("gh issue close"), 0)
  end,

  test_merge_closed_pr_head_mismatch_does_not_reenter_reviewing = function()
    local event = merge_ready()
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "feedface", "CLOSED")

    local result = run_merge(event, opts("merge-head-advanced-closed-pr", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr merge"), 0)
    t.eq(count_calls("gh issue close"), 0)
  end,

  test_merge_queue_result_errors_for_retry_before_merged_fact = function()
    local event = merge_ready()
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_pr_merge({ origin_marker })
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_write_env("1")
    mock_pr_merge({ origin_marker })
    mock_merging_comment()
    mock_pr_merge_command()
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "def456", "OPEN")

    local result = run_merge(event, opts("merge-queued-not-merged", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(count_calls("gh issue close"), 0)
  end,

  test_merge_retry_after_failed_merge_with_moved_head_goes_to_fixing = function()
    local event = merge_ready()
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments_with_merging(event))
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "feedface")

    local result = run_merge(event, opts("merge-failed-moved-head-self-heal", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.eq(count_calls("gh pr merge"), 0)
    t.eq(count_calls("gh issue close"), 0)
    local label_raise = find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.eq(label_raise.payload.add_labels[1], "fkst-dev:fixing")
    t.is_true(has_value(label_raise.payload.remove_labels, "fkst-dev:merging"))
    t.eq(find_causal_raise(result, "devloop_fixing").payload.schema, "github-devloop.fixing.v1")
  end,

  test_merge_queued_pr_finalizes_on_later_poll_when_bot_merging_marker_exists = function()
    local event = merge_ready()
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments_with_merging(event))
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "def456", "MERGED", "owner/repo", false, "MERGEABLE", "CLEAN", "COMPLETED", "SUCCESS", "2026-06-03T02:03:04Z")
    mock_write_env("1")

    local result = run_merge(event, opts("merge-queued-later-poll-merged", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(count_calls("gh pr merge"), 0)
    t.eq(count_calls("gh issue close"), 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.is_true(find_raise(result.raises, "github-proxy.github_pr_comment_request").payload.body:find("fkst:github-devloop:merged:v1", 1, true) ~= nil)
  end,

  test_merge_pending_checks_errors_for_retry_without_advance = function()
    local event = merge_ready()
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "def456", "OPEN", "owner/repo", false, "MERGEABLE", "CLEAN", "PENDING", "")

    local result = run_merge(event, opts("merge-pending-checks", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr merge"), 0)
  end,

	  test_merge_command_failure_errors_for_retry = function()
	    local event = merge_ready()
	    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_pr_merge({ origin_marker })
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_write_env("1")
    mock_pr_merge({ origin_marker })
    mock_merging_comment()
    mock_pr_merge_command(1, "merge race")

    local result = run_merge(event, opts("merge-command-failure", { FKST_GITHUB_WRITE = "1" }))
	    t.eq(result.exit_code, 1)
	    t.eq(#result.raises, 0)
	    t.eq(count_calls("gh issue close"), 0)

	    local merge_calls_after_failure = count_calls("gh pr merge")
	    mock_bot_env()
	    mock_write_env("1")
	    mock_issue_merge({ "fkst-dev:merging" }, merge_comments_with_merging(event))
	    mock_pr_merge({ origin_marker })
	    mock_issue_merge({ "fkst-dev:merging" }, merge_comments_with_merging(event))
	    mock_write_env("1")
	    mock_pr_merge({ origin_marker })
	    mock_pr_merge_command()
	    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "def456", "MERGED", "owner/repo", false, "MERGEABLE", "CLEAN", "COMPLETED", "SUCCESS", "2026-06-03T02:03:04Z")

	    local retry = run_merge(event, opts("merge-command-failure-retry-from-merging", { FKST_GITHUB_WRITE = "1" }))
	    t.eq(retry.exit_code, 0)
	    t.eq(#retry.raises, 1)
	    t.eq(count_calls("gh pr merge"), merge_calls_after_failure + 1)
	    t.eq(count_calls("gh issue close"), 0)
	  end,

  test_merge_stale_idempotent_forged_and_foreign_skip = function()
    local event = merge_ready()
    local merge_calls_before = count_calls("gh pr merge")
    mock_bot_env()
    mock_issue_merge({ "fkst-dev:reviewing" }, {
      core.state_marker(event.proposal_id, "reviewing", event.version),
    })
    mock_pr_merge({ m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev") })
    local stale = run_merge(event, opts("merge-stale"))
    t.eq(stale.exit_code, 0)
    t.eq(#stale.raises, 0)
    t.eq(count_calls("gh pr merge"), merge_calls_before)

    mock_bot_env()
    mock_issue_merge({ "fkst-dev:merged" }, {
      core.state_marker(event.proposal_id, "merged", event.version),
      m_builders.merged_marker(core, event.proposal_id, event.pr_number, event.version, event.reviewed_head_sha),
    })
    mock_pr_merge({ m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev") })
    local idempotent = run_merge(event, opts("merge-idempotent"))
    t.eq(idempotent.exit_code, 0)
    t.eq(#idempotent.raises, 0)
    t.eq(count_calls("gh pr merge"), merge_calls_before)

    local forged = m_builders.merge_ready_marker(event.proposal_id, event.pr_number, event.version, event.review_proposal_id, event.review_dedup_key, event.reviewed_head_sha)
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, {
      core.state_marker(event.proposal_id, "merge-ready", event.version),
      m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev"),
      { body = forged, author_login = "ordinary-user" },
    })
    mock_pr_merge({ m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev") })
    local forged_result = run_merge(event, opts("merge-forged", { FKST_GITHUB_WRITE = "1" }))
    t.eq(forged_result.exit_code, 1)
    t.eq(#forged_result.raises, 0)
    t.eq(count_calls("gh pr merge"), merge_calls_before)

    local foreign = merge_ready({ proposal_id = "github-devloop/issue/owner/repo/../../42" })
    local foreign_result = run_merge(foreign, opts("merge-foreign"))
    t.eq(foreign_result.exit_code, 0)
    t.eq(#foreign_result.raises, 0)
  end,
}
