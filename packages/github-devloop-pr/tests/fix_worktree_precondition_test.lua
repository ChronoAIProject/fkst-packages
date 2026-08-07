local git_adapter = require("forge.git")
local precondition_module = require("departments.fix.worktree_precondition")
local t = fkst.test

local proposal_id = "github-devloop/issue/owner/repo/42"
local branch = "devloop-owner-repo-42-01HY"
local worktree = "/tmp/fkst-packages-test/github-devloop/worktrees/issue-42"

local function result(exit_code, stderr)
  return { stdout = "", stderr = stderr or "", exit_code = exit_code }
end

local function fixture(opts)
  local config = opts or {}
  local calls = {}
  local responses = config.responses or {}
  local worktree_state = {
    tracked_dirty = config.tracked_dirty == true,
    untracked = config.untracked == true,
    merge_head = config.merge_head == true,
  }
  local git = git_adapter.new(function(request)
    table.insert(calls, request.argv)
    local response = table.remove(responses, 1) or result(0)
    if response.exit_code == 0 and request.argv[4] == "reset" then
      worktree_state.tracked_dirty = false
      worktree_state.merge_head = false
    elseif response.exit_code == 0 and request.argv[4] == "clean" then
      worktree_state.untracked = false
    end
    return response
  end)
  local guard = precondition_module.make({
    git = git,
    codex_runs = function()
      if config.codex_error ~= nil then
        error(config.codex_error)
      end
      return { running = config.running or {}, recent = {} }
    end,
    now = function() return 1000 end,
  })
  return guard, calls, worktree_state
end

local function call_equals(actual, expected)
  t.eq(#actual, #expected)
  for index, value in ipairs(expected) do
    t.eq(actual[index], value)
  end
end

local function error_text(fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  return tostring(err)
end

return {
  test_dirty_worktree_without_live_owner_is_reset_to_branch_then_cleaned = function()
    local guard, calls, worktree_state = fixture({
      tracked_dirty = true,
      untracked = true,
    })

    local established, owner = guard.establish(worktree, branch, proposal_id)

    t.eq(established, true)
    t.eq(owner, nil)
    t.eq(#calls, 2)
    call_equals(calls[1], {
      "git", "-C", worktree, "reset", "--hard", "refs/heads/" .. branch,
    })
    call_equals(calls[2], { "git", "-C", worktree, "clean", "-fd" })
    t.eq(worktree_state.tracked_dirty, false)
    t.eq(worktree_state.untracked, false)
  end,

  test_stale_merge_head_without_live_owner_is_cleared_by_branch_reset = function()
    local guard, calls, worktree_state = fixture({ merge_head = true })

    local established = guard.establish(worktree, branch, proposal_id)

    t.eq(established, true)
    t.eq(#calls, 2)
    t.eq(worktree_state.merge_head, false)
  end,

  test_precondition_defers_for_live_implement_owner_with_same_proposal = function()
    local guard, calls = fixture({
      running = {
        {
          role = "implement",
          proposal_id = proposal_id,
          dedup_key = "ready/version-owned-by-implement",
          status = "running",
          lease_expires_at_ms = 1001000,
        },
      },
    })

    local established, owner = guard.establish(worktree, branch, proposal_id)

    t.eq(established, false)
    t.eq(owner.role, "implement")
    t.eq(owner.proposal_id, proposal_id)
    t.eq(#calls, 0)
  end,

  test_precondition_ignores_expired_run_for_same_proposal = function()
    local guard, calls = fixture({
      running = {
        {
          role = "implement",
          proposal_id = proposal_id,
          status = "running",
          lease_expires_at_ms = 999000,
        },
      },
    })

    local established = guard.establish(worktree, branch, proposal_id)

    t.eq(established, true)
    t.eq(#calls, 2)
  end,

  test_precondition_reset_failure_is_fail_closed = function()
    local guard, calls = fixture({
      responses = { result(7, "reset refused") },
    })

    local err = error_text(function()
      guard.establish(worktree, branch, proposal_id)
    end)

    t.is_true(err:find("fix-worktree-reset-failed", 1, true) ~= nil)
    t.is_true(err:find("reset refused", 1, true) ~= nil)
    t.eq(#calls, 1)
  end,

  test_precondition_clean_failure_is_fail_closed = function()
    local guard, calls = fixture({
      responses = { result(0), result(8, "clean refused") },
    })

    local err = error_text(function()
      guard.establish(worktree, branch, proposal_id)
    end)

    t.is_true(err:find("fix-worktree-clean-failed", 1, true) ~= nil)
    t.is_true(err:find("clean refused", 1, true) ~= nil)
    t.eq(#calls, 2)
  end,

  test_precondition_owner_query_failure_is_fail_closed_without_touching_worktree = function()
    local guard, calls = fixture({ codex_error = "codex run surface unavailable" })

    local err = error_text(function()
      guard.establish(worktree, branch, proposal_id)
    end)

    t.is_true(err:find("fix-worktree-owner-check-failed", 1, true) ~= nil)
    t.eq(#calls, 0)
  end,
}
