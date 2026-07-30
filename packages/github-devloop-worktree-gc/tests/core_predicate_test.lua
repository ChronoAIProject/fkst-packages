-- Safety unit tests for the worktree-GC removable-predicate. Fixtures use the REAL
-- devloop.base.implement_branch so branch strings match exactly between the porcelain
-- worktrees and the codex-run -> branch live-set derivation (no re-implementation).

local core = require("core")
local base = require("devloop.base")
local t = fkst.test

local REPO = "ChronoAIProject/fkst-packages"
local OLD_RT = "/runtime/dogfood-rt-packages.1111"
local CUR_RT = "/runtime/dogfood-rt-packages.2222"
local NOW_S = 1000000
local NOW_MS = NOW_S * 1000

local function running_row(issue, dedup, lease_offset_ms)
  return {
    status = "running",
    proposal_id = "github-devloop/issue/" .. REPO .. "/" .. tostring(issue),
    dedup_key = dedup,
    lease_expires_at_ms = NOW_MS + (lease_offset_ms or 600000),
  }
end

local function porcelain(entries)
  local lines = {}
  for _, e in ipairs(entries) do
    lines[#lines + 1] = "worktree " .. e.path
    lines[#lines + 1] = "HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    if e.detached then
      lines[#lines + 1] = "detached"
    elseif e.branch then
      lines[#lines + 1] = "branch refs/heads/" .. e.branch
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

local function removable_has(result, path)
  for _, c in ipairs(result.removable) do
    if c.path == path then
      return true
    end
  end
  return false
end

local function skip_reason(result, path)
  for _, s in ipairs(result.skipped) do
    if s.path == path then
      return s.reason
    end
  end
  return nil
end

-- Fixed identities (branches computed by the real helper).
local ORPHAN_BRANCH = base.implement_branch(REPO, 111, "dedup-orphan")
local TERMINAL_BRANCH = base.implement_branch(REPO, 222, "dedup-terminal")
local CURRENT_BRANCH = base.implement_branch(REPO, 333, "dedup-current")

local MAIN_PATH = "/home/dev/fkst-packages"
local ORPHAN_PATH = OLD_RT .. "/worktrees/devloop-orphan-111"
local TERMINAL_PATH = OLD_RT .. "/worktrees/devloop-terminal-222"
local CURRENT_PATH = CUR_RT .. "/worktrees/devloop-current-333"
local STABLE_PATH = "/runtime/dogfood-durable-packages-worktrees/worktrees/devloop-current-333"
local DETACHED_PATH = OLD_RT .. "/worktrees/devloop-detached-444"
local FOREIGN_PATH = OLD_RT .. "/worktrees/some-other-555"

local FULL_PORCELAIN = porcelain({
  { path = MAIN_PATH, branch = "integration" },
  { path = ORPHAN_PATH, branch = ORPHAN_BRANCH },
  { path = TERMINAL_PATH, branch = TERMINAL_BRANCH },
  { path = CURRENT_PATH, branch = CURRENT_BRANCH },
  { path = DETACHED_PATH, detached = true },
  { path = FOREIGN_PATH, branch = "feature/some-external-branch" },
})

return {
  -- Orphan-after-restart: a live running codex row keyed to the orphan branch keeps its
  -- old-RT worktree even though the path is under a dead runtime root.
  test_orphan_after_restart_is_kept = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    t.eq(live.complete, true)
    local result = core.classify(worktrees, live)
    t.eq(removable_has(result, ORPHAN_PATH), false)
    t.eq(skip_reason(result, ORPHAN_PATH), "live-branch")
  end,

  test_live_retry_row_keeps_base_branch_worktree = function()
    local branch = base.implement_branch(REPO, 333, "dedup-retry")
    local path = STABLE_PATH .. "-retry"
    local worktrees = core.parse_worktrees(porcelain({
      { path = path, branch = branch },
    }))
    local live = core.live_branches({
      running_row(333, "dedup-retry/reimplement/2"),
    }, NOW_MS)
    local result = core.classify(worktrees, live, {
      terminal_issues = {
        ["github-devloop/issue/" .. REPO .. "/333"] = true,
      },
    })

    t.eq(removable_has(result, path), false)
    t.eq(skip_reason(result, path), "live-branch")
  end,

  -- Terminal deterministic worktree with NO live row is the removable target.
  test_terminal_old_rt_is_removable = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    local result = core.classify(worktrees, live, {
      terminal_issues = { ["github-devloop/issue/" .. REPO .. "/222"] = true },
    })
    t.eq(removable_has(result, TERMINAL_PATH), true)
    t.eq(result.removable[1].issue_ref.proposal_id, "github-devloop/issue/" .. REPO .. "/222")
  end,

  test_inactive_worktree_without_terminal_proof_is_skipped = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    local result = core.classify(worktrees, live)
    t.eq(removable_has(result, CURRENT_PATH), false)
    t.eq(skip_reason(result, CURRENT_PATH), "terminal-unverified")
  end,

  test_branch_issue_ref_parses_normal_github_issue_branch = function()
    local issue_ref = core.issue_ref_from_branch(CURRENT_BRANCH)
    t.eq(issue_ref.repo, REPO)
    t.eq(issue_ref.issue, "333")
    t.eq(issue_ref.proposal_id, "github-devloop/issue/" .. REPO .. "/333")
    t.eq(issue_ref.source_ref.kind, "external")
    t.eq(issue_ref.source_ref.ref, REPO .. "#issue/333")
  end,

  test_current_rt_terminal_issue_is_removable = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    local result = core.classify(worktrees, live, {
      terminal_issues = {
        ["github-devloop/issue/" .. REPO .. "/333"] = true,
      },
    })
    t.eq(removable_has(result, CURRENT_PATH), true)
  end,

  test_current_rt_without_terminal_proof_is_skipped = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    local result = core.classify(worktrees, live, { terminal_issues = {} })
    t.eq(removable_has(result, CURRENT_PATH), false)
    t.eq(skip_reason(result, CURRENT_PATH), "terminal-unverified")
  end,

  test_stable_worktree_without_terminal_proof_is_skipped = function()
    local worktrees = core.parse_worktrees(porcelain({
      { path = STABLE_PATH, branch = CURRENT_BRANCH },
    }))
    local live = core.live_branches({}, NOW_MS)
    local result = core.classify(worktrees, live, { terminal_issues = {} })
    t.eq(removable_has(result, STABLE_PATH), false)
    t.eq(skip_reason(result, STABLE_PATH), "terminal-unverified")
  end,

  test_stable_terminal_worktree_carries_issue_ref_for_fresh_recheck = function()
    local worktrees = core.parse_worktrees(porcelain({
      { path = STABLE_PATH, branch = CURRENT_BRANCH },
    }))
    local live = core.live_branches({}, NOW_MS)
    local result = core.classify(worktrees, live, {
      terminal_issues = {
        ["github-devloop/issue/" .. REPO .. "/333"] = true,
      },
    })
    t.eq(removable_has(result, STABLE_PATH), true)
    t.eq(result.removable[1].issue_ref.proposal_id, "github-devloop/issue/" .. REPO .. "/333")
  end,

  -- Detached, foreign, and main-checkout worktrees are never removable.
  test_detached_foreign_main_skipped = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({}, NOW_MS)
    local result = core.classify(worktrees, live)
    t.eq(skip_reason(result, DETACHED_PATH), "detached-or-non-branch")
    t.eq(skip_reason(result, FOREIGN_PATH), "non-deterministic-branch")
    t.eq(skip_reason(result, MAIN_PATH), "non-deterministic-branch")
    t.eq(removable_has(result, DETACHED_PATH), false)
    t.eq(removable_has(result, FOREIGN_PATH), false)
    t.eq(removable_has(result, MAIN_PATH), false)
  end,

  -- Fail-open: one unparseable LIVE running row makes the live set incomplete, so
  -- NOTHING is removable this pass (a live worktree could belong to that row).
  test_fail_open_on_unparseable_running_row = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local rows = {
      running_row(111, "dedup-orphan"),
      { status = "running", proposal_id = "totally-unparseable", dedup_key = "x", lease_expires_at_ms = NOW_MS + 600000 },
    }
    local live = core.live_branches(rows, NOW_MS)
    t.eq(live.complete, false)
    local result = core.classify(worktrees, live)
    t.eq(#result.removable, 0)
    t.eq(skip_reason(result, TERMINAL_PATH), "fail-open-incomplete-live-set")
  end,

  -- An expired-lease running row is NOT live (matches devloop liveness): its old-RT
  -- worktree becomes removable.
  test_expired_lease_row_not_live = function()
    local worktrees = core.parse_worktrees(porcelain({
      { path = ORPHAN_PATH, branch = ORPHAN_BRANCH },
    }))
    local live = core.live_branches({ running_row(111, "dedup-orphan", -1) }, NOW_MS) -- lease already past
    t.eq(live.complete, true)
    local result = core.classify(worktrees, live, {
      terminal_issues = { ["github-devloop/issue/" .. REPO .. "/111"] = true },
    })
    t.eq(removable_has(result, ORPHAN_PATH), true)
  end,

  -- A running row with MISSING lease info is treated as live (conservative keep).
  test_missing_lease_treated_live = function()
    local worktrees = core.parse_worktrees(porcelain({
      { path = ORPHAN_PATH, branch = ORPHAN_BRANCH },
    }))
    local row = running_row(111, "dedup-orphan")
    row.lease_expires_at_ms = nil
    local live = core.live_branches({ row }, NOW_MS)
    local result = core.classify(worktrees, live)
    t.eq(removable_has(result, ORPHAN_PATH), false)
    t.eq(skip_reason(result, ORPHAN_PATH), "live-branch")
  end,
}
