local attempt_ownership = require("departments.implement.attempt_ownership")
local t = fkst.test

local WORKTREE = "/tmp/fkst-packages-test/github-devloop/owned-attempt"

local function outcome(kind)
  return {
    kind = kind,
    branch = "devloop/issue/owner/repo/42/change-123",
    head_sha = "def456",
  }
end

local function fake_git(opts)
  opts = opts or {}
  local calls = { promoted = 0, removed = 0 }
  local git = {
    show_ref_branch_quiet = function()
      return { stdout = "", stderr = "", exit_code = 0 }
    end,
    branch_head = function()
      return { stdout = "abc123\n", stderr = "", exit_code = 0 }
    end,
    is_ancestor = function()
      return { stdout = "", stderr = "", exit_code = opts.divergent and 1 or 0 }
    end,
    update_branch_ref = function()
      calls.promoted = calls.promoted + 1
      return { stdout = "", stderr = "", exit_code = 0 }
    end,
    git_worktree_remove_if_present = function(path, timeout)
      t.eq(path, WORKTREE)
      t.eq(timeout, 60)
      calls.removed = calls.removed + 1
      return { stdout = "", stderr = "", exit_code = 0 }
    end,
  }
  return git, calls
end

return {
  test_success_promotes_then_handles_then_releases = function()
    local git, calls = fake_git()
    local handled = 0
    local completed = attempt_ownership.complete(
      git, WORKTREE, outcome("implementing"), "abc123", function()
        handled = handled + 1
      end)
    t.eq(completed, true)
    t.eq(calls.promoted, 1)
    t.eq(handled, 1)
    t.eq(calls.removed, 1)
  end,

  test_checkpoint_promotes_before_release = function()
    local git, calls = fake_git()
    attempt_ownership.complete(
      git, WORKTREE, outcome("implement-checkpoint"), "abc123", function() end)
    t.eq(calls.promoted, 1)
    t.eq(calls.removed, 1)
  end,

  test_refusal_and_failure_release_without_promotion = function()
    for _, kind in ipairs({ "implementation-refusal", "impl-failed" }) do
      local git, calls = fake_git()
      attempt_ownership.complete(git, WORKTREE, outcome(kind), "abc123", function() end)
      t.eq(calls.promoted, 0)
      t.eq(calls.removed, 1)
    end
  end,

  test_stale_promotion_skips_outcome_and_releases = function()
    local git, calls = fake_git({ divergent = true })
    local handled = 0
    local completed, reason = attempt_ownership.complete(
      git, WORKTREE, outcome("implementing"), "abc123", function()
        handled = handled + 1
      end)
    t.eq(completed, false)
    t.eq(reason, "stale-divergent")
    t.eq(handled, 0)
    t.eq(calls.promoted, 0)
    t.eq(calls.removed, 1)
  end,

  test_deferred_dispatch_releases_unstarted_attempt = function()
    local git, calls = fake_git()
    attempt_ownership.release(git, WORKTREE)
    t.eq(calls.removed, 1)
  end,

  test_outcome_handler_error_releases_promoted_attempt_before_reraise = function()
    local git, calls = fake_git()
    local ok, err = pcall(function()
      attempt_ownership.complete(
        git, WORKTREE, outcome("implementing"), "abc123", function()
          error("synthetic outcome failure")
        end)
    end)
    t.eq(ok, false)
    t.is_true(tostring(err):find("synthetic outcome failure", 1, true) ~= nil)
    t.eq(calls.promoted, 1)
    t.eq(calls.removed, 1)
  end,
}
