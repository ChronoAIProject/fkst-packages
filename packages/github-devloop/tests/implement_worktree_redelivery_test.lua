local h = require("tests.devloop_helpers")
local devloop_base = require("devloop.base")
local worktree_lifecycle = require("departments.implement.worktree")

local t = h.t
local ready = h.ready
local deterministic_branch_for = h.deterministic_branch_for
local count_calls = h.count_calls

local runtime = "/tmp/fkst-packages-test/github-devloop/runtime"

local function mock_current_worktree(event, branch, status_stdout)
  local worktree = devloop_base.implement_worktree_path(runtime, "owner/repo", 42, event.dedup_key)
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = runtime,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("git worktree list --porcelain", {
    stdout = "worktree " .. worktree .. "\nHEAD abc123\nbranch refs/heads/" .. branch .. "\n\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("status --porcelain", {
    stdout = status_stdout,
    stderr = "",
    exit_code = 0,
  })
  return worktree
end

local function assert_preserved(worktree, actual, preserved)
  t.eq(actual, worktree)
  t.eq(preserved, true)
  t.eq(count_calls("reset --hard"), 0)
  t.eq(count_calls("clean -fd"), 0)
  t.eq(count_calls("git worktree remove --force"), 0)
  t.eq(count_calls("git worktree add"), 0)
end

return {
  test_same_version_dirty_worktree_is_preserved = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    local worktree = mock_current_worktree(
      event,
      branch,
      " M backend/src/schedule/mod.rs\n?? backend/tests/schedule.rs\n"
    )

    local actual, preserved = worktree_lifecycle.prepare_worktree(
      "owner/repo", 42, event, branch, "abc123", nil)

    assert_preserved(worktree, actual, preserved)
  end,

  test_cross_repository_base_dirty_worktree_is_preserved = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local worktree = mock_current_worktree(
      event,
      branch,
      " M backend/src/schedule/mod.rs\n?? backend/tests/schedule.rs\n"
    )

    local actual, preserved = worktree_lifecycle.prepare_worktree_from_base(
      "owner/repo", 42, event, branch, "abc123")

    assert_preserved(worktree, actual, preserved)
  end,

  test_same_version_clean_worktree_keeps_fresh_start_reconciliation = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    t.mock_command("show-ref --verify --quiet", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    local worktree = mock_current_worktree(event, branch, "")
    t.mock_command("reset --hard", {
      stdout = "HEAD is now at abc123\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("clean -fd", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local actual, preserved = worktree_lifecycle.prepare_worktree(
      "owner/repo", 42, event, branch, "abc123", nil)

    t.eq(actual, worktree)
    t.eq(preserved, false)
    t.eq(count_calls("reset --hard"), 1)
    t.eq(count_calls("clean -fd"), 1)
  end,
}
