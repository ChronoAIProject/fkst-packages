local fixture = require("tests.integration_implement_meta_helpers")
local entity_lib = fixture.entity_lib
local h = fixture.h
local forks = fixture.forks
local payloads_builders = fixture.payloads_builders
local m_facts = fixture.m_facts
local t = fixture.t
local core = fixture.core
local gh_argv = fixture.gh_argv
local action_label = fixture.action_label
local reason_label = fixture.reason_label
local has_value = fixture.has_value
local opts = fixture.opts
local source_ref = fixture.source_ref
local issue = fixture.issue
local reached = fixture.reached
local unresolved = fixture.unresolved
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
local run_loop = fixture.run_loop
local run_implement = fixture.run_implement
local run_observe_pr = fixture.run_observe_pr
local run_review_pr = fixture.run_review_pr
local run_review_result = fixture.run_review_result
local run_fix = fixture.run_fix
local run_review_loop = fixture.run_review_loop
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
local mock_setup_worktree = fixture.mock_setup_worktree
local deterministic_branch_for = fixture.deterministic_branch_for
local mock_fresh_implement_worktree = fixture.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree = fixture.mock_existing_empty_implement_worktree
local mock_existing_empty_implement_worktree_reuse = fixture.mock_existing_empty_implement_worktree_reuse
local mock_existing_dirty_implement_worktree_reuse = fixture.mock_existing_dirty_implement_worktree_reuse
local mock_existing_implement_branch = fixture.mock_existing_implement_branch
local mock_git_commit = fixture.mock_git_commit
local mock_result_checkpoint = fixture.mock_result_checkpoint
local mock_git_push = fixture.mock_git_push
local mock_implement_codex = fixture.mock_implement_codex
local mock_git_status = fixture.mock_git_status
local mock_branch_diff_paths = fixture.mock_branch_diff_paths
local mock_write_env = fixture.mock_write_env
local mock_bot_env = fixture.mock_bot_env
local mock_issue_view_failure = fixture.mock_issue_view_failure
local count_calls = fixture.count_calls
local find_raise = fixture.find_raise
local codex_status = fixture.codex_status
local m_builders = fixture.m_builders
local find_comment_with = fixture.find_comment_with
local assert_implement_attempt = fixture.assert_implement_attempt
local count_issue_comment_raises = fixture.count_issue_comment_raises
local find_label_with_added = fixture.find_label_with_added
local assert_worktree_ready_state = fixture.assert_worktree_ready_state
local mock_no_implemented_branch_ahead = fixture.mock_no_implemented_branch_ahead

return {
  test_implement_crash_before_marker_reuses_existing_branch_commit = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" })
    mock_existing_implement_branch("def456")
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
      stderr = "",
      exit_code = 0,
    })
    mock_existing_empty_implement_worktree_reuse(nil, branch, "1")
    mock_implement_codex()
    mock_git_status("")
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    mock_result_checkpoint("def456", branch)
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "def456\n",
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-existing-branch-reuse"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 4)
    t.eq(count_issue_comment_raises(result.raises), 3)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    t.eq(find_label_with_added(result.raises, "fkst-dev:implementing").payload.add_labels[1], "fkst-dev:implementing")
    local comment = find_comment_with(result.raises, "fkst:github-devloop:implementing:v1").payload.body
    local fact = m_facts.implementing_fact({ comment }, event.proposal_id, event.dedup_key)
    t.eq(fact.branch, branch)
    t.eq(fact.head_sha, "def456")
    t.eq(count_calls("git worktree add"), 0)
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("merge --no-edit 'abc123'"), 1)
    t.eq(count_calls("status --porcelain"), 1)
    t.eq(count_calls("impl-failed"), 0)
  end,

  test_implement_existing_worktree_for_other_issue_does_not_affect_fresh_attempt = function()
    local event = ready({
      proposal_id = "github-devloop/issue/owner/repo/4",
      dedup_key = "ready/consensus-github-devloop/issue/owner/repo/4/2026-06-03T01-02-03Z",
      source_ref = {
        kind = "external",
        ref = "owner/repo#issue/4",
      },
    })
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(event.proposal_id, "ready", default_marker_version),
    }, { number = 4 })
    mock_fresh_implement_worktree({
      issue_number = 4,
      impl_version = event.dedup_key,
      additional_registrations = {
        { path = "/tmp/devloop-owner-repo-42-01HY", branch = "devloop-owner-repo-42-01HY" },
      },
    })
    mock_implement_codex()
    mock_git_status(" M packages/github-devloop/departments/implement/main.lua\n")
    mock_git_commit("def456", branch)

    local result = run_implement(event, opts("implement-boundary-worktree"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 4)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    t.eq(count_calls("git worktree list"), 4)
    t.eq(count_calls("codex exec"), 1)
  end,

  test_implement_empty_git_status_marks_impl_failed_with_failure_marker = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready" })
    mock_fresh_implement_worktree()
    mock_implement_codex(0, "")
    mock_git_status("")
    t.mock_command("rev-list --count", {
      stdout = "0\n",
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-no-changes"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 5)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    t.eq(find_label_with_added(result.raises, "fkst-dev:impl-failed").payload.add_labels[1], "fkst-dev:impl-failed")
    local comment_raise = find_comment_with(result.raises, "fkst:github-devloop:impl-failure:v1")
    t.is_true(comment_raise.payload.body:find("github-devloop implementation failed: no-changes", 1, true) ~= nil)
  end,

  test_implement_clean_worktree_with_branch_ahead_marks_implementing = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" })
    mock_fresh_implement_worktree()
    mock_implement_codex(0, "Committed implementation directly.")
    mock_git_status("")
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    mock_result_checkpoint("def456", branch)
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "def456\n",
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-clean-ahead"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 4)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    t.eq(find_label_with_added(result.raises, "fkst-dev:implementing").payload.add_labels[1], "fkst-dev:implementing")
    local comment = find_comment_with(result.raises, "fkst:github-devloop:implementing:v1").payload.body
    local fact = m_facts.implementing_fact({ comment }, event.proposal_id, event.dedup_key)
    t.eq(fact.branch, branch)
    t.eq(fact.head_sha, "def456")
    t.eq(count_calls("impl-failed"), 0)
  end,

  test_implement_existing_empty_branch_still_marks_no_changes_failed = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready" })
    mock_existing_empty_implement_worktree()
    mock_implement_codex(0, "")
    mock_git_status("")
    t.mock_command("rev-list --count", {
      stdout = "0\n",
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-existing-empty-branch-no-changes"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 5)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    t.eq(find_label_with_added(result.raises, "fkst-dev:impl-failed").payload.add_labels[1], "fkst-dev:impl-failed")
    local comment_raise = find_comment_with(result.raises, "fkst:github-devloop:impl-failure:v1")
    t.is_true(comment_raise.payload.body:find("github-devloop implementation failed: no-changes", 1, true) ~= nil)
    t.eq(count_calls("git worktree add"), 1)
    t.eq(count_calls("codex exec"), 1)
  end,

  test_implement_existing_empty_worktree_reuses_and_converges_when_codex_commits = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" })
    local worktree = mock_existing_empty_implement_worktree_reuse(nil, branch, "1")
    mock_implement_codex(0, "Committed implementation directly.")
    mock_git_status("")
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    mock_result_checkpoint("def456", branch)
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "def456\n",
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-existing-worktree-reuse"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 4)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    t.eq(find_label_with_added(result.raises, "fkst-dev:implementing").payload.add_labels[1], "fkst-dev:implementing")
    local comment = find_comment_with(result.raises, "fkst:github-devloop:implementing:v1").payload.body
    local fact = m_facts.implementing_fact({ comment }, event.proposal_id, event.dedup_key)
    t.eq(fact.branch, branch)
    t.eq(fact.head_sha, "def456")
    t.is_true(comment:find(worktree, 1, true) ~= nil)
    t.eq(count_calls("git worktree list --porcelain"), 3)
    t.eq(count_calls("git worktree add"), 0)
    t.eq(count_calls("codex exec"), 1)
  end,

  test_implement_reused_worktree_is_reset_and_cleaned_before_merge = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" })
    local worktree = mock_existing_dirty_implement_worktree_reuse(nil, branch, "1")
    mock_implement_codex(0, "Committed implementation directly.")
    mock_git_status("")
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    mock_result_checkpoint("def456", branch)
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "def456\n",
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-dirty-worktree-reuse"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 4)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    t.eq(count_calls("reset --hard"), 1)
    t.eq(count_calls("clean -fd"), 1)
    t.eq(count_calls("merge --no-edit 'abc123'"), 1)

    local reset_before_merge = false
    local reset_seen = false
    for _, call in ipairs(t.command_calls()) do
      if gh_argv.argv_contains(call, { "git", "-C", worktree, "reset", "--hard" }) then
        reset_seen = true
      elseif gh_argv.argv_contains(call, { "git", "-C", worktree, "merge", "--no-edit", "abc123" }) then
        reset_before_merge = reset_seen
      end
    end
    t.eq(reset_before_merge, true)
  end,
}
