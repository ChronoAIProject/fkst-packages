local h = require("tests.devloop_helpers")
local t = h.t
local harvest = require("departments.implement.harvest")
local verdict = require("departments.implement.local_iteration_verdict")

local base_sha = "1111111111111111111111111111111111111111"

-- A git handle whose three census reads are fully controlled: the whole defect is that a worktree
-- can answer HEAD correctly while its tree is still being written, so the gate has to be provable
-- without waiting for a real half-written checkout to occur.
local function git_stub(opts)
  local o = opts or {}
  return {
    status_porcelain = function()
      return o.status or { exit_code = 0, stdout = "" }
    end,
    tracked_files = function()
      return o.tracked or { exit_code = 0, stdout = "a.lua\nb.lua\nc.lua\n" }
    end,
    commit_tracked_files = function()
      return o.expected or { exit_code = 0, stdout = "a.lua\nb.lua\nc.lua\n" }
    end,
  }
end

return {
  test_fully_materialized_tree_is_accepted = function()
    local ok, detail = harvest.probe_tree_is_materialized(git_stub(), "/w", base_sha)
    t.is_true(ok)
    t.eq(detail, nil)
  end,

  -- The observed production failure: files the commit contains are absent from the worktree, so
  -- `run.sh` reported `No such file or directory` and that became a SEMANTIC verdict.
  test_missing_tracked_file_is_rejected_by_the_census = function()
    local ok, detail = harvest.probe_tree_is_materialized(git_stub({
      tracked = { exit_code = 0, stdout = "a.lua\nb.lua\n" },
    }), "/w", base_sha)
    t.is_true(not ok)
    t.is_true(tostring(detail):find("tracked%-census%-mismatch") ~= nil)
    t.is_true(tostring(detail):find("worktree=2") ~= nil)
    t.is_true(tostring(detail):find("commit=3") ~= nil)
  end,

  -- `status --porcelain` and the census see different halves of the same failure: this one is
  -- visible to status (the file existed and went away), the previous one is not.
  test_dirty_worktree_is_rejected = function()
    local ok, detail = harvest.probe_tree_is_materialized(git_stub({
      status = { exit_code = 0, stdout = " D packages/github-devloop/departments/observe_issue/main.lua\n" },
    }), "/w", base_sha)
    t.is_true(not ok)
    t.is_true(tostring(detail):find("worktree%-dirty") ~= nil)
  end,

  test_unavailable_census_command_is_rejected_not_assumed_clean = function()
    local ok, detail = harvest.probe_tree_is_materialized(git_stub({
      tracked = { exit_code = 128, stdout = "", stderr = "not a git repository" },
    }), "/w", base_sha)
    t.is_true(not ok)
    t.is_true(tostring(detail):find("tracked%-census%-unavailable") ~= nil)
  end,

  -- Acceptance 1/2: an unmaterialized tree must never become a verdict about the code. Every probe
  -- status other than `completed` classifies INDETERMINATE, which is the retryable setup outcome.
  test_unmaterialized_probe_never_produces_a_code_verdict = function()
    local classified = verdict.classify({ kind = "SEMANTIC_FAIL" }, {
      status = "tree-not-materialized",
      base_sha = base_sha,
      head_readback = base_sha,
      result = { kind = "SEMANTIC_FAIL" },
    })
    t.eq(classified, "INDETERMINATE")
    t.is_true(classified ~= "BASE_RED")
    t.is_true(classified ~= "OWN_LOCAL_RED")
  end,

  -- Acceptance 3: the gate must not degrade into "everything is retryable" -- a completed probe
  -- whose base genuinely fails on assertions still yields its existing verdict.
  test_genuine_base_failure_is_unaffected = function()
    t.eq(verdict.classify({ kind = "SEMANTIC_FAIL" }, {
      status = "completed",
      base_sha = base_sha,
      head_readback = base_sha,
      result = { kind = "SEMANTIC_FAIL" },
    }), "BASE_RED")
    t.eq(verdict.classify({ kind = "SEMANTIC_FAIL" }, {
      status = "completed",
      base_sha = base_sha,
      head_readback = base_sha,
      result = { kind = "PASS" },
    }), "OWN_LOCAL_RED")
  end,
}
