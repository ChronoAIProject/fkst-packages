local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local forks = require("devloop.forks")
local payloads_builders = require("devloop.payloads.builders")
local m_facts = require("devloop.markers.facts")
local t = h.t
local core = h.core
local gh_argv = require("testkit_internal.gh_argv_mock")
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
local run_review_meta = h.run_review_meta
local run_merge = h.run_merge
local json_string = h.json_string
local render_comment = h.render_comment
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
local mock_setup_worktree = h.mock_setup_worktree
local deterministic_branch_for = h.deterministic_branch_for
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree = h.mock_existing_empty_implement_worktree
local mock_existing_empty_implement_worktree_reuse = h.mock_existing_empty_implement_worktree_reuse
local mock_existing_dirty_implement_worktree_reuse = h.mock_existing_dirty_implement_worktree_reuse
local mock_outside_runtime_implement_worktree_rebuild = h.mock_outside_runtime_implement_worktree_rebuild
local mock_multiple_outside_runtime_implement_worktrees_rebuild = h.mock_multiple_outside_runtime_implement_worktrees_rebuild
local mock_existing_implement_branch = h.mock_existing_implement_branch
local mock_git_commit = h.mock_git_commit
local mock_result_checkpoint = h.mock_result_checkpoint
local mock_git_push = h.mock_git_push
local mock_existing_devloop_worktree = h.mock_existing_devloop_worktree
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_branch_diff_paths = h.mock_branch_diff_paths
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_issue_view_failure = h.mock_issue_view_failure
local count_calls = h.count_calls
local find_raise = h.find_raise
local codex_status = require("testkit_internal.codex_lifetime_witness")
local m_builders = require("devloop.markers.builders")

local function find_comment_with(raises, text)
  return find_raise(raises, "github-proxy.github_issue_comment_request", function(payload)
    return tostring(payload.body or ""):find(text, 1, true) ~= nil
  end)
end

local function assert_implement_attempt(raises, event, attempt)
  local comment_raise = find_comment_with(raises, "fkst:github-devloop:implement-attempt:v1")
  t.is_true(comment_raise ~= nil)
  t.is_true(comment_raise.payload.body:find('proposal="' .. event.proposal_id .. '"', 1, true) ~= nil)
  t.is_true(comment_raise.payload.body:find('dedup="' .. event.dedup_key .. '"', 1, true) ~= nil)
  t.is_true(comment_raise.payload.body:find('attempt="' .. tostring(attempt or 1) .. '"', 1, true) ~= nil)
end

local function count_issue_comment_raises(raises)
  local count = 0
  for _, raised in ipairs(raises or {}) do
    if tostring(raised.queue or "") == "github-proxy.github_issue_comment_request" then
      count = count + 1
    end
  end
  return count
end

local function find_label_with_added(raises, label)
  return find_raise(raises, "github-proxy.github_issue_label_request", function(payload)
    for _, added in ipairs(payload.add_labels or {}) do
      if tostring(added) == tostring(label) then
        return true
      end
    end
    return false
  end)
end

local function assert_worktree_ready_state(raises, event)
  local comment_raise = find_comment_with(raises, "github-devloop implementation worktree ready")
  t.is_true(comment_raise ~= nil)
  t.is_true(comment_raise.payload.body:find(core.state_marker(event.proposal_id, "implementing", event.dedup_key), 1, true) ~= nil)
  t.is_true(comment_raise.payload.body:find("fkst:github-devloop:implement-attempt:v1", 1, true) ~= nil)
  t.eq(m_facts.implementing_fact({ comment_raise.payload.body }, event.proposal_id, event.dedup_key), nil)
  t.is_true(find_label_with_added(raises, "fkst-dev:implementing") ~= nil)
end

local function mock_no_implemented_branch_ahead(branch)
  t.mock_command("git rev-list --count abc123..refs/heads/" .. tostring(branch), {
    stdout = "0\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  entity_lib = entity_lib,
  h = h,
  forks = forks,
  payloads_builders = payloads_builders,
  m_facts = m_facts,
  t = t,
  core = core,
  gh_argv = gh_argv,
  action_label = action_label,
  reason_label = reason_label,
  has_value = has_value,
  opts = opts,
  source_ref = source_ref,
  issue = issue,
  reached = reached,
  unresolved = unresolved,
  ready = ready,
  reviewing = reviewing,
  review_reached = review_reached,
  review_unresolved = review_unresolved,
  fixing = fixing,
  pr_link_marker_for_fix = pr_link_marker_for_fix,
  review_meta_event = review_meta_event,
  merge_ready = merge_ready,
  run_observe = run_observe,
  run_result = run_result,
  run_loop = run_loop,
  run_implement = run_implement,
  run_observe_pr = run_observe_pr,
  run_review_pr = run_review_pr,
  run_review_result = run_review_result,
  run_fix = run_fix,
  run_review_loop = run_review_loop,
  run_review_meta = run_review_meta,
  run_merge = run_merge,
  json_string = json_string,
  render_comment = render_comment,
  default_marker_version = default_marker_version,
  mock_issue_state = mock_issue_state,
  state_from_labels = state_from_labels,
  with_default_state_marker = with_default_state_marker,
  mock_issue_body = mock_issue_body,
  mock_issue_result = mock_issue_result,
  mock_issue_loop = mock_issue_loop,
  mock_issue_implement = mock_issue_implement,
  mock_issue_implement_raw = mock_issue_implement_raw,
  mock_issue_reviewing = mock_issue_reviewing,
  mock_issue_review = mock_issue_review,
  mock_issue_fix = mock_issue_fix,
  mock_issue_fix_for_event = mock_issue_fix_for_event,
  mock_issue_review_meta = mock_issue_review_meta,
  mock_issue_merge = mock_issue_merge,
  merge_comments = merge_comments,
  mock_pr_origin = mock_pr_origin,
  mock_pr_merge = mock_pr_merge,
  mock_pr_merge_rollup = mock_pr_merge_rollup,
  mock_merging_comment = mock_merging_comment,
  mock_pr_merge_command = mock_pr_merge_command,
  has_call = has_call,
  mock_issue_close = mock_issue_close,
  merge_comments_with_merging = merge_comments_with_merging,
  mock_pr_fix = mock_pr_fix,
  mock_pr_origin_sequence = mock_pr_origin_sequence,
  mock_pr_head = mock_pr_head,
  mock_pr_diff = mock_pr_diff,
  mock_setup_worktree = mock_setup_worktree,
  deterministic_branch_for = deterministic_branch_for,
  mock_fresh_implement_worktree = mock_fresh_implement_worktree,
  mock_existing_empty_implement_worktree = mock_existing_empty_implement_worktree,
  mock_existing_empty_implement_worktree_reuse = mock_existing_empty_implement_worktree_reuse,
  mock_existing_dirty_implement_worktree_reuse = mock_existing_dirty_implement_worktree_reuse,
  mock_outside_runtime_implement_worktree_rebuild = mock_outside_runtime_implement_worktree_rebuild,
  mock_multiple_outside_runtime_implement_worktrees_rebuild = mock_multiple_outside_runtime_implement_worktrees_rebuild,
  mock_existing_implement_branch = mock_existing_implement_branch,
  mock_git_commit = mock_git_commit,
  mock_result_checkpoint = mock_result_checkpoint,
  mock_git_push = mock_git_push,
  mock_existing_devloop_worktree = mock_existing_devloop_worktree,
  mock_implement_codex = mock_implement_codex,
  mock_git_status = mock_git_status,
  mock_branch_diff_paths = mock_branch_diff_paths,
  mock_write_env = mock_write_env,
  mock_bot_env = mock_bot_env,
  mock_issue_view_failure = mock_issue_view_failure,
  count_calls = count_calls,
  find_raise = find_raise,
  codex_status = codex_status,
  m_builders = m_builders,
  find_comment_with = find_comment_with,
  assert_implement_attempt = assert_implement_attempt,
  count_issue_comment_raises = count_issue_comment_raises,
  find_label_with_added = find_label_with_added,
  assert_worktree_ready_state = assert_worktree_ready_state,
  mock_no_implemented_branch_ahead = mock_no_implemented_branch_ahead,
}
