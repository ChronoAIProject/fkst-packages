local devloop_base = require("devloop.base")
local gh_argv = require("testkit_internal.gh_argv_mock")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local t = h.t
local core = h.core

local function attempt_fixture(name)
  local event = h.fixing({
    gate_baseline_sha = "abc123",
    gate_failure_excerpt = "mergeable-conflicting",
  })
  local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
  local gate_comment = "github-devloop merge gate failed: mergeable-conflicting"
    .. "\n" .. core.state_marker(event.proposal_id, "fixing", event.version)
    .. "\n" .. m_builders.merge_gate_marker(
      event.proposal_id,
      event.pr_number,
      event.version,
      event.review_proposal_id,
      event.review_dedup_key,
      event.reviewed_head_sha,
      event.gate_baseline_sha,
      "mergeable-conflicting"
    )
  local origin_marker = m_builders.pr_origin_marker(
    event.proposal_id, "42", branch, event.version, "dev")
  h.mock_bot_env()
  h.mock_write_env("1")
  h.mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, {
    core.state_marker(event.proposal_id, "fixing", event.version),
    gate_comment,
  }, branch, event.version)
  h.mock_pr_fix({ origin_marker }, branch, "def456")
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
    stderr = "",
    exit_code = 0,
  })
  local worktree = h.mock_existing_fix_worktree(branch, "def456", nil, {
    sha = "abc123",
    exit_code = 0,
    stdout = "Merge made by the ort strategy.\n",
  })
  return {
    name = name,
    event = event,
    branch = branch,
    worktree = worktree,
    gate_comment = gate_comment,
    origin_marker = origin_marker,
  }
end

local function mock_successful_writeback(fixture)
  h.mock_implement_codex(0, "fixed after guarded worktree cleanup")
  h.mock_git_status(" M packages/github-devloop/core.lua\n")
  h.mock_git_commit("feedface", fixture.branch)
  h.mock_write_env("1")
  h.mock_issue_fix_for_event(fixture.event, { "fkst-dev:fixing" }, {
    core.state_marker(fixture.event.proposal_id, "fixing", fixture.event.version),
    fixture.gate_comment,
  }, fixture.branch, fixture.event.version)
  h.mock_git_push(fixture.branch)
  h.mock_pr_fix({ fixture.origin_marker }, fixture.branch, "feedface")
end

local function command_indexes(fixture)
  local indexes = {}
  for index, call in ipairs(t.command_calls()) do
    if gh_argv.argv_contains(call, {
      "git", "-C", fixture.worktree, "reset", "--hard", "refs/heads/" .. fixture.branch,
    }) then
      indexes.reset = index
    elseif gh_argv.argv_contains(call, {
      "git", "-C", fixture.worktree, "clean", "-fd",
    }) then
      indexes.clean = index
    elseif gh_argv.argv_contains(call, {
      "git", "-C", fixture.worktree, "merge", "--no-edit", "abc123",
    }) then
      indexes.merge = index
    elseif tostring(call.rendered or ""):find("codex exec", 1, true) ~= nil then
      indexes.codex = index
    end
  end
  return indexes
end

local function assert_cleanup_precedes_merge_and_codex(fixture)
  local indexes = command_indexes(fixture)
  t.is_true(indexes.reset ~= nil)
  t.is_true(indexes.clean ~= nil)
  t.is_true(indexes.merge ~= nil)
  t.is_true(indexes.codex ~= nil)
  t.is_true(indexes.reset < indexes.clean)
  t.is_true(indexes.clean < indexes.merge)
  t.is_true(indexes.merge < indexes.codex)
end

return {
  test_dirty_worktree_without_live_owner_is_reset_then_merge_proceeds = function()
    local fixture = attempt_fixture("fix-dirty-worktree-unowned")
    mock_successful_writeback(fixture)

    local result = h.run_fix(fixture.event, h.opts(fixture.name, { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0, tostring(result.error))
    assert_cleanup_precedes_merge_and_codex(fixture)
    t.eq(h.count_calls("reset --hard refs/heads/" .. fixture.branch), 1)
    t.eq(h.count_calls("clean -fd"), 1)
    t.eq(h.count_calls("merge --no-edit 'abc123'"), 1)
  end,

  test_stale_merge_head_without_live_owner_is_cleared_before_merge = function()
    local fixture = attempt_fixture("fix-stale-merge-head-unowned")
    mock_successful_writeback(fixture)

    local result = h.run_fix(fixture.event, h.opts(fixture.name, { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0, tostring(result.error))
    assert_cleanup_precedes_merge_and_codex(fixture)
    t.eq(h.count_calls("reset --hard refs/heads/" .. fixture.branch), 1)
    t.eq(h.count_calls("merge --no-edit 'abc123'"), 1)
  end,
}
