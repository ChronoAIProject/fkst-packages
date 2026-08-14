local fixture = require("tests.merge_queue_wip_helpers")
local entity_lib = fixture.entity_lib
local devloop_base = fixture.devloop_base
local base_ids = fixture.base_ids
local h = fixture.h
local transition_version = fixture.transition_version
local payloads_builders = fixture.payloads_builders
local m_mq = fixture.m_mq
local t = fixture.t
local core = fixture.core
local entity_read_mocks = fixture.entity_read_mocks
local m_builders = fixture.m_builders
local opts = fixture.opts
local merge_ready = fixture.merge_ready
local ready = fixture.ready
local run_merge = fixture.run_merge
local run_implement = fixture.run_implement
local mock_bot_env = fixture.mock_bot_env
local mock_write_env = fixture.mock_write_env
local mock_issue_merge = fixture.mock_issue_merge
local mock_issue_implement = fixture.mock_issue_implement
local mock_pr_merge = fixture.mock_pr_merge
local mock_merging_comment = fixture.mock_merging_comment
local mock_issue_close = fixture.mock_issue_close
local mock_fresh_implement_worktree = fixture.mock_fresh_implement_worktree
local mock_implement_codex = fixture.mock_implement_codex
local mock_git_status = fixture.mock_git_status
local merge_comments = fixture.merge_comments
local count_calls = fixture.count_calls
local find_raise = fixture.find_raise
local find_causal_raise = fixture.find_causal_raise
local render_comment = fixture.render_comment
local json_string = fixture.json_string
local json_literal = fixture.json_literal
local branch_for_pr = fixture.branch_for_pr
local run_merge_queue_tick = fixture.run_merge_queue_tick
local run_starvation_merge_queue_tick = fixture.run_starvation_merge_queue_tick
local mock_repo_env = fixture.mock_repo_env
local mock_branch_config_env = fixture.mock_branch_config_env
local mock_write_env_many = fixture.mock_write_env_many
local merge_comments_with_origin = fixture.merge_comments_with_origin
local merge_comments_for_event = fixture.merge_comments_for_event
local event_for_pr = fixture.event_for_pr
local mock_claimed_issue_for_event = fixture.mock_claimed_issue_for_event
local mock_queue_pr = fixture.mock_queue_pr
local mock_merge_pr_view = fixture.mock_merge_pr_view
local mock_merged_pr_view = fixture.mock_merged_pr_view
local mock_diff_name_only = fixture.mock_diff_name_only
local mock_current_base_head = fixture.mock_current_base_head
local mock_candidate_head_contains_base = fixture.mock_candidate_head_contains_base
local mock_merge_command = fixture.mock_merge_command
local mock_issue_close_for = fixture.mock_issue_close_for
local mock_queue_list = fixture.mock_queue_list
local predecessor_set_for = fixture.predecessor_set_for

return {
  test_non_head_dirty_merge_state_with_current_base_contained_holds_without_fixing = function()
    local current_head = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    local base_event = merge_ready()
    local older = event_for_pr(9, 44, "2026-06-03T00-00-00Z", "aaa111")
    local current_review = devloop_base.pr_review_proposal_id("owner/repo", base_event.pr_number, base_event.version, current_head)
    local current = merge_ready({
      review_proposal_id = current_review,
      review_dedup_key = "consensus:" .. current_review .. "/review",
      reviewed_head_sha = current_head,
    })
    local origin_marker = m_builders.pr_origin_marker(current.proposal_id, "42", "devloop-owner-repo-42-01HY", current.version, "dev")
    local base_head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    mock_bot_env()
    mock_write_env("1")
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(current))
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", current.reviewed_head_sha, "OPEN", "owner/repo", false, "MERGEABLE", "DIRTY")
    mock_queue_list({ 9 })
    mock_queue_pr(older, "2026-06-03T00:00:00Z")
    mock_current_base_head(base_head)
    t.mock_command("git merge-base --is-ancestor " .. base_head .. " " .. current.reviewed_head_sha, {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local result = run_merge(current, opts("merge-conflicting-base-contained", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0, tostring(result.error or result.stderr))
    t.eq(count_calls("gh pr merge"), 0)
    t.eq(find_raise(result.raises, "devloop_fixing"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    local wait_comment = find_raise(result.raises, "github-proxy.github_pr_comment_request")
    t.is_true(wait_comment.payload.body:find("fkst:github-devloop:merge-gate-wait:v1", 1, true) ~= nil)
    t.is_true(wait_comment.payload.body:find('reason="merge-state-dirty"', 1, true) ~= nil)
  end,

  test_merge_batch_window_merges_disjoint_pair_in_one_pass = function()
    local first = event_for_pr(7, 42, "2026-06-03T00-00-00Z", "def456")
    local second = event_for_pr(8, 43, "2026-06-03T00-01-00Z", "fed789")
    mock_bot_env()
    mock_write_env_many(64)
    mock_repo_env()
    mock_queue_list({ 7, 8 })
    mock_queue_pr(first, "2026-06-03T01:00:00Z")
    mock_queue_pr(second, "2026-06-03T01:01:00Z")
    mock_merge_pr_view(first)
    mock_claimed_issue_for_event(first, 2)
    mock_merge_pr_view(first)
    mock_merge_pr_view(first)
    mock_merge_command(first)
    mock_merged_pr_view(first)
    mock_issue_close_for(first)
    mock_diff_name_only(7, { "packages/a.lua" })
    mock_current_base_head("abc124")
    mock_claimed_issue_for_event(second)
    mock_candidate_head_contains_base(second, true)
    mock_diff_name_only(8, { "packages/b.lua" })
    mock_merge_pr_view(second)
    mock_claimed_issue_for_event(second, 2)
    mock_merge_pr_view(second)
    mock_merge_pr_view(second)
    mock_merge_command(second)
    mock_merged_pr_view(second)
    mock_issue_close_for(second)
    mock_current_base_head("abc125")
    mock_queue_list({})

    local result = run_merge_queue_tick(opts("merge-batch-window-disjoint", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 2)
    t.eq(count_calls("gh issue close"), 0)
    t.eq(#result.raises, 2)
  end,

  test_merge_batch_window_stops_when_candidate_head_lacks_current_base = function()
    local first = event_for_pr(7, 42, "2026-06-03T00-00-00Z", "def456")
    local second = event_for_pr(8, 43, "2026-06-03T00-01-00Z", "fed789")
    mock_bot_env()
    mock_write_env_many(64)
    mock_repo_env()
    mock_queue_list({ 7, 8 })
    mock_queue_pr(first, "2026-06-03T01:00:00Z")
    mock_queue_pr(second, "2026-06-03T01:01:00Z")
    mock_merge_pr_view(first)
    mock_claimed_issue_for_event(first, 2)
    mock_merge_pr_view(first)
    mock_merge_pr_view(first)
    mock_merge_command(first)
    mock_merged_pr_view(first)
    mock_issue_close_for(first)
    mock_diff_name_only(7, { "packages/a.lua" })
    mock_current_base_head("abc124")
    mock_claimed_issue_for_event(second)
    mock_candidate_head_contains_base(second, false)
    mock_queue_list({ 8 })
    mock_queue_pr(second, "2026-06-03T01:01:00Z")

    local result = run_merge_queue_tick(opts("merge-batch-window-current-base-missing", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(count_calls("gh issue close"), 0)
    t.eq(count_calls("gh pr diff '8' --repo 'owner/repo' --name-only"), 0)
    local chained = find_raise(result.raises, "devloop_merge_queue_tick")
    t.is_true(chained ~= nil)
    t.eq(chained.payload.schema, "github-devloop.merge-queue-tick.v1")
    t.eq(chained.payload.cause.merged_pr_number, 7)
    t.eq(chained.payload.cause.next_pr_number, 8)
    t.is_true(chained.payload.dedup_key:find("merged-pr/7/next-pr/8/fed789", 1, true) ~= nil)
  end,

  test_merge_queue_self_requeue_is_quiescent_when_queue_empty_after_progress = function()
    local first = event_for_pr(7, 42, "2026-06-03T00-00-00Z", "def456")
    mock_bot_env()
    mock_write_env_many(64)
    mock_repo_env()
    mock_queue_list({ 7 })
    mock_queue_pr(first, "2026-06-03T01:00:00Z")
    mock_merge_pr_view(first)
    mock_claimed_issue_for_event(first, 2)
    mock_merge_pr_view(first)
    mock_merge_pr_view(first)
    mock_merge_command(first)
    mock_merged_pr_view(first)
    mock_issue_close_for(first)
    mock_diff_name_only(7, { "packages/a.lua" })
    mock_current_base_head("abc124")
    mock_queue_list({})

    local result = run_merge_queue_tick(opts("merge-queue-self-requeue-empty", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(find_raise(result.raises, "devloop_merge_queue_tick"), nil)
  end,

  test_merge_queue_head_pending_ci_holds_then_completes = function()
    local next = event_for_pr(8, 43, "2026-06-03T00-01-00Z", "fed789")
    mock_bot_env()
    mock_write_env_many(64)
    mock_repo_env()
    mock_queue_list({ 8 })
    mock_queue_pr(next, "2026-06-03T01:01:00Z")
    mock_claimed_issue_for_event(next)
    mock_diff_name_only(8, { "packages/b.lua" })
    mock_merge_pr_view(next, "OPEN", "MERGEABLE", "CLEAN", "PENDING", "")

    local retry = run_merge_queue_tick(opts("merge-queue-head-pending-ci", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(retry.exit_code, 0, tostring(retry.error or retry.stderr))
    t.eq(#retry.raises, 1)
    t.eq(count_calls("gh pr merge"), 0)
    t.eq(find_raise(retry.raises, "devloop_fixing"), nil)
    t.eq(find_raise(retry.raises, "devloop_merge_queue_tick"), nil)
    local wait_comment = find_raise(retry.raises, "github-proxy.github_pr_comment_request")
    t.is_true(wait_comment.payload.body:find("fkst:github-devloop:merge-gate-wait:v1", 1, true) ~= nil)
    t.is_true(wait_comment.payload.body:find('reason="rollup-pending"', 1, true) ~= nil)

    mock_bot_env()
    mock_write_env_many(64)
    mock_repo_env()
    mock_queue_list({ 8 })
    mock_queue_pr(next, "2026-06-03T01:01:00Z")
    mock_claimed_issue_for_event(next)
    mock_merge_pr_view(next)
    mock_merge_pr_view(next)
    mock_merge_pr_view(next)
    mock_merge_command(next)
    mock_merged_pr_view(next)
    mock_issue_close_for(next)
    mock_diff_name_only(8, { "packages/b.lua" })
    mock_current_base_head("abc124")
    mock_queue_list({})

    local completed = run_merge_queue_tick(opts("merge-queue-head-pending-ci-retry", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(completed.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(find_raise(completed.raises, "devloop_fixing"), nil)
  end,

  test_merge_batch_window_stops_on_overlapping_files = function()
    local first = event_for_pr(7, 42, "2026-06-03T00-00-00Z", "def456")
    local second = event_for_pr(8, 43, "2026-06-03T00-01-00Z", "fed789")
    mock_bot_env()
    mock_write_env("1")
    mock_repo_env()
    mock_queue_list({ 7, 8 })
    mock_queue_pr(first, "2026-06-03T01:00:00Z")
    mock_queue_pr(second, "2026-06-03T01:01:00Z")
    mock_merge_pr_view(first)
    mock_write_env("1")
    mock_claimed_issue_for_event(first, 2)
    mock_merge_pr_view(first)
    mock_merge_pr_view(first)
    mock_merge_command(first)
    mock_merged_pr_view(first)
    mock_issue_close_for(first)
    mock_diff_name_only(7, { "packages/shared.lua" })
    mock_current_base_head("abc124")
    mock_claimed_issue_for_event(second)
    mock_candidate_head_contains_base(second, true)
    mock_diff_name_only(8, { "packages/shared.lua" })
    mock_queue_list({ 8 })
    mock_queue_pr(second, "2026-06-03T01:01:00Z")

    local result = run_merge_queue_tick(opts("merge-batch-window-overlap", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(count_calls("gh issue close"), 0)
    local chained = find_raise(result.raises, "devloop_merge_queue_tick")
    t.is_true(chained ~= nil)
    t.eq(chained.payload.cause.merged_pr_number, 7)
    t.eq(chained.payload.cause.next_pr_number, 8)
  end,

  test_merge_batch_window_stops_when_candidate_gate_fails = function()
    local first = event_for_pr(7, 42, "2026-06-03T00-00-00Z", "def456")
    local second_head = string.rep("b", 40)
    local second_base = string.rep("a", 40)
    local second = event_for_pr(8, 43, "2026-06-03T00-01-00Z", second_head)
    mock_bot_env()
    mock_write_env("1")
    mock_repo_env()
    mock_queue_list({ 7, 8 })
    mock_queue_pr(first, "2026-06-03T01:00:00Z")
    mock_queue_pr(second, "2026-06-03T01:01:00Z")
    mock_merge_pr_view(first)
    mock_write_env("1")
    mock_claimed_issue_for_event(first, 2)
    mock_merge_pr_view(first)
    mock_merge_pr_view(first)
    mock_merge_command(first)
    mock_merged_pr_view(first)
    mock_issue_close_for(first)
    mock_diff_name_only(7, { "packages/a.lua" })
    mock_current_base_head("abc124")
    mock_claimed_issue_for_event(second)
    mock_candidate_head_contains_base(second, true)
    mock_diff_name_only(8, { "packages/b.lua" })
    mock_write_env("1")
    mock_branch_config_env()
    mock_queue_list({})
    mock_claimed_issue_for_event(second, 1)
    mock_merge_pr_view(second, "OPEN", "MERGEABLE", "CLEAN", "COMPLETED", "FAILURE", second_base)
    mock_merge_pr_view(second, "OPEN", "MERGEABLE", "CLEAN", "COMPLETED", "FAILURE", second_base)
    h.mock_required_check_runs_for(second.reviewed_head_sha, "failure")
    mock_queue_list({ 8 })
    mock_queue_pr(second, "2026-06-03T01:01:00Z", "fixing", second.version .. "/fix/1")

    local result = h.with_new_failure_set_evidence({
      pr_number = second.pr_number,
      base_commit = second_base,
      head_commit = second_head,
    }, function()
      return run_merge_queue_tick(opts("merge-batch-window-gate-fails", {
        FKST_GITHUB_WRITE = "1",
        FKST_GITHUB_REPO = "owner/repo",
      }))
    end)
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(count_calls("gh issue close"), 0)
    t.eq(find_causal_raise(result, "devloop_fixing") ~= nil, true)
  end,

  test_merge_batch_window_does_not_skip_failed_candidate_to_later_disjoint_pr = function()
    local first = event_for_pr(7, 42, "2026-06-03T00-00-00Z", "def456")
    local second = event_for_pr(8, 43, "2026-06-03T00-01-00Z", "fed789")
    local third = event_for_pr(9, 44, "2026-06-03T00-02-00Z", "abc999")
    mock_bot_env()
    mock_write_env("1")
    mock_repo_env()
    mock_queue_list({ 7, 8, 9 })
    mock_queue_pr(first, "2026-06-03T01:00:00Z")
    mock_queue_pr(second, "2026-06-03T01:01:00Z")
    mock_queue_pr(third, "2026-06-03T01:02:00Z")
    mock_merge_pr_view(first)
    mock_write_env("1")
    mock_claimed_issue_for_event(first, 2)
    mock_merge_pr_view(first)
    mock_merge_pr_view(first)
    mock_merge_command(first)
    mock_merged_pr_view(first)
    mock_issue_close_for(first)
    mock_diff_name_only(7, { "packages/a.lua" })
    mock_current_base_head("abc124")
    mock_claimed_issue_for_event(second)
    mock_candidate_head_contains_base(second, true)
    mock_diff_name_only(8, { "packages/b.lua" })
    mock_write_env("1")
    mock_write_env("1")
    mock_write_env("1")
    mock_branch_config_env()
    mock_queue_list({})
    mock_claimed_issue_for_event(second, 1)
    mock_merge_pr_view(second, "OPEN", "MERGEABLE", "CLEAN", "COMPLETED", "FAILURE")
    mock_merge_pr_view(second, "OPEN", "MERGEABLE", "CLEAN", "COMPLETED", "FAILURE")
    h.mock_required_check_runs_for(second.reviewed_head_sha, "failure")
    mock_queue_list({ 8, 9 })
    mock_queue_pr(second, "2026-06-03T01:01:00Z", "fixing", second.version .. "/fix/1")
    mock_queue_pr(third, "2026-06-03T01:02:00Z")

    local result = run_merge_queue_tick(opts("merge-batch-window-no-skip-after-gate-fail", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(count_calls("gh issue close"), 0)
    t.eq(count_calls("gh pr diff '9' --repo 'owner/repo' --name-only"), 0)
  end,

}
