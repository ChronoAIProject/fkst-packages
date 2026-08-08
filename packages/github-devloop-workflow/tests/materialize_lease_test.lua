local lease = require("core.materialize.lease")
local t = fkst.test

local core = {
  has_label = function()
    return false
  end,
  invalidate_entity_after_write = function()
  end,
}

local function release_deps(result, calls)
  return {
    release_issue_claim_if_self = function(core_arg, dept, repo, issue_number, proposal_id, reason)
      calls[#calls + 1] = {
        core = core_arg,
        dept = dept,
        repo = repo,
        issue_number = issue_number,
        proposal_id = proposal_id,
        reason = reason,
      }
      return result
    end,
  }
end

local tests = {
  test_done_release_delegates_to_shared_label_claim_owner = function()
    local calls = {}
    local ok = lease.release_done_claim(
      core,
      release_deps(true, calls),
      "owner/repo",
      42,
      "github-devloop/issue/owner/repo/42"
    )
    t.is_true(ok)
    t.eq(#calls, 1)
    t.eq(calls[1].core, core)
    t.eq(calls[1].dept, "workflow_materialize_next")
    t.eq(calls[1].repo, "owner/repo")
    t.eq(calls[1].issue_number, 42)
    t.eq(calls[1].proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(calls[1].reason, "workflow terminal done")
  end,

  test_done_release_propagates_shared_claim_rejection = function()
    local calls = {}
    local ok = lease.release_done_claim(
      core,
      release_deps(false, calls),
      "owner/repo",
      42,
      "github-devloop/issue/owner/repo/42"
    )
    t.eq(ok, false)
    t.eq(#calls, 1)
  end,

  -- A "done" terminal (every slot merged) closes the completed origin idea issue.
  test_done_close_origin_closes_the_issue = function()
    local closes = {}
    local deps = {
      write_enabled = function()
        return true
      end,
      issue_close = function(repo, issue_number, disposition, timeout)
        closes[#closes + 1] = { repo = repo, issue_number = issue_number, disposition = disposition, timeout = timeout }
        return { exit_code = 0 }
      end,
    }
    local ok = lease.close_done_origin(core, deps, "owner/repo", 42, "github-devloop/issue/owner/repo/42")
    t.is_true(ok)
    t.eq(#closes, 1)
    t.eq(closes[1].repo, "owner/repo")
    t.eq(closes[1].issue_number, 42)
    t.eq(closes[1].disposition.kind, "completed")
  end,

  -- Dry-run posture: without FKST_GITHUB_WRITE the close is logged, not executed.
  test_done_close_origin_dry_run_does_not_close = function()
    local closes = {}
    local deps = {
      write_enabled = function()
        return false
      end,
      issue_close = function(repo, issue_number, disposition, timeout)
        closes[#closes + 1] = { repo = repo, issue_number = issue_number }
      end,
    }
    local ok = lease.close_done_origin(core, deps, "owner/repo", 42, "github-devloop/issue/owner/repo/42")
    t.is_true(ok)
    t.eq(#closes, 0)
  end,
}

return tests
