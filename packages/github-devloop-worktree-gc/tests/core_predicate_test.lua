-- Safety unit tests for the worktree-GC removable-predicate. Fixtures use the REAL
-- devloop.base.implement_branch so branch strings match exactly between the porcelain
-- worktrees and the codex-run -> branch live-set derivation (no re-implementation).

local core = require("core")
local base = require("devloop.base")
local marker_builders = require("devloop.markers.builders")
local devloop_state = require("devloop.state")
local t = fkst.test

local REPO = "ChronoAIProject/fkst-packages"
local OLD_RT = "/runtime/dogfood-rt-packages.1111"
local CUR_RT = "/runtime/dogfood-rt-packages.2222"
local IMPLEMENTATION_ROOT = "/runtime/dogfood-durable-packages-worktrees"
local NOW_S = 1000000
local NOW_MS = NOW_S * 1000

local function running_row(issue, dedup, lease_offset_ms, role)
  return {
    role = role,
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
local STABLE_PATH = IMPLEMENTATION_ROOT .. "/worktrees/devloop-current-333"
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

local function comment(body, author_login)
  return {
    body = body,
    author_login = author_login or base._test_bot_login,
    created_at = "2026-07-22T00:01:00Z",
  }
end

local function implementation_marker()
  return marker_builders.implementing_marker(
    "github-devloop/issue/" .. REPO .. "/333",
    "dedup-current",
    CURRENT_BRANCH,
    "1111111111111111111111111111111111111111",
    "dev",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  )
end

local function checkpoint_marker()
  return marker_builders.implement_checkpoint_marker(
    "github-devloop/issue/" .. REPO .. "/333",
    "dedup-current",
    CURRENT_BRANCH,
    "1111111111111111111111111111111111111111",
    "dev",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    1
  )
end

local function failure_marker(dedup_key, attempt)
  return '<!-- fkst:github-devloop:impl-failure:v1 proposal="github-devloop/issue/'
    .. REPO .. '/333" reason="local-iteration-failed" attempt="' .. tostring(attempt or 1)
    .. '" dedup="' .. tostring(dedup_key or "dedup-current") .. '" -->'
end

return {
  -- Orphan-after-restart: a live running codex row keyed to the orphan branch keeps its
  -- old-RT worktree even though the path is under a dead runtime root.
  test_orphan_after_restart_is_kept = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    t.eq(live.complete, true)
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT)
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
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT, {
      released_branches = {
        [branch] = true,
      },
    })

    t.eq(removable_has(result, path), false)
    t.eq(skip_reason(result, path), "live-branch")
  end,

  -- An old-runtime deterministic worktree with NO live row is reclaimable.
  test_terminal_old_rt_is_removable = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT)
    t.eq(removable_has(result, TERMINAL_PATH), true)
  end,

  test_branch_issue_ref_parses_normal_github_issue_branch = function()
    local issue_ref = core.issue_ref_from_branch(CURRENT_BRANCH)
    t.eq(issue_ref.repo, REPO)
    t.eq(issue_ref.issue, "333")
    t.eq(issue_ref.proposal_id, "github-devloop/issue/" .. REPO .. "/333")
    t.eq(issue_ref.source_ref.kind, "external")
    t.eq(issue_ref.source_ref.ref, REPO .. "#issue/333")
  end,

  test_published_output_releases_exact_branch = function()
    local issue_ref = core.issue_ref_from_branch(CURRENT_BRANCH)
    local fact = core.branch_release_fact({ comment(implementation_marker()) }, issue_ref, CURRENT_BRANCH)
    t.eq(fact.kind, "published")
    t.eq(fact.branch, CURRENT_BRANCH)
  end,

  test_checkpoint_does_not_release_inflight_branch = function()
    local issue_ref = core.issue_ref_from_branch(CURRENT_BRANCH)
    local fact = core.branch_release_fact({ comment(checkpoint_marker()) }, issue_ref, CURRENT_BRANCH)
    t.eq(fact, nil)
  end,

  test_current_impl_failure_classifies_residue_disposable = function()
    local proposal_id = "github-devloop/issue/" .. REPO .. "/333"
    local comments = {
      comment(devloop_state.state_marker(proposal_id, "impl-failed", "dedup-current") .. "\n" .. failure_marker()),
    }
    local fact = core.branch_release_fact(comments, core.issue_ref_from_branch(CURRENT_BRANCH), CURRENT_BRANCH)
    t.eq(fact.kind, "disposable-residue")
    t.eq(fact.branch, CURRENT_BRANCH)
  end,

  test_retry_impl_failure_releases_reused_base_branch = function()
    local proposal_id = "github-devloop/issue/" .. REPO .. "/333"
    local retry_dedup = "dedup-current/reimplement/2"
    local comments = {
      comment(devloop_state.state_marker(proposal_id, "impl-failed", retry_dedup)
        .. "\n" .. failure_marker(retry_dedup, 2)),
    }
    local fact = core.branch_release_fact(
      comments,
      core.issue_ref_from_branch(CURRENT_BRANCH),
      CURRENT_BRANCH
    )
    t.eq(fact.kind, "disposable-residue")
    t.eq(fact.branch, CURRENT_BRANCH)
  end,

  test_stale_impl_failure_does_not_release_reentered_attempt = function()
    local proposal_id = "github-devloop/issue/" .. REPO .. "/333"
    local comments = {
      comment(failure_marker()),
      comment(devloop_state.state_marker(proposal_id, "implementing", "dedup-current")),
    }
    t.eq(core.branch_release_fact(comments, core.issue_ref_from_branch(CURRENT_BRANCH), CURRENT_BRANCH), nil)
  end,

  test_untrusted_progress_marker_does_not_release_branch = function()
    local comments = { comment(implementation_marker(), "attacker") }
    t.eq(core.branch_release_fact(comments, core.issue_ref_from_branch(CURRENT_BRANCH), CURRENT_BRANCH), nil)
  end,

  test_progress_marker_for_different_branch_does_not_release_branch = function()
    local marker = marker_builders.implementing_marker(
      "github-devloop/issue/" .. REPO .. "/333",
      "dedup-current",
      ORPHAN_BRANCH,
      "1111111111111111111111111111111111111111",
      "dev",
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    t.eq(core.branch_release_fact({ comment(marker) }, core.issue_ref_from_branch(CURRENT_BRANCH), CURRENT_BRANCH), nil)
  end,

  test_terminal_issue_releases_branch = function()
    local proposal_id = "github-devloop/issue/" .. REPO .. "/333"
    local fact = core.branch_release_fact({
      comment(devloop_state.state_marker(proposal_id, "merged", "dedup-current")),
    }, core.issue_ref_from_branch(CURRENT_BRANCH), CURRENT_BRANCH)
    t.eq(fact.kind, "terminal")
    t.eq(fact.branch, CURRENT_BRANCH)
  end,

  test_fix_owner_branch_comes_from_trusted_implementation_fact = function()
    local proposal_id = "github-devloop/issue/" .. REPO .. "/333"
    t.eq(core.fix_owner_branch({ comment(implementation_marker()) }, proposal_id), CURRENT_BRANCH)
    t.eq(core.fix_owner_branch({ comment(implementation_marker(), "attacker") }, proposal_id), nil)
  end,

  test_current_rt_finalized_branch_is_removable_without_terminal_issue = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT, {
      released_branches = {
        [CURRENT_BRANCH] = true,
      },
    })
    t.eq(removable_has(result, CURRENT_PATH), true)
  end,

  test_live_branch_wins_over_finalized_release_fact = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(333, "dedup-current") }, NOW_MS)
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT, {
      released_branches = {
        [CURRENT_BRANCH] = true,
      },
    })
    t.eq(removable_has(result, CURRENT_PATH), false)
    t.eq(skip_reason(result, CURRENT_PATH), "live-branch")
  end,

  test_live_fix_resolves_immutable_owner_branch = function()
    local work_unit_key = "review-feedback/head/review-dedup"
    local resolved = 0
    local live = core.live_branches({
      running_row(333, work_unit_key, nil, "fix"),
    }, NOW_MS, function(row)
      resolved = resolved + 1
      t.eq(row.dedup_key, work_unit_key)
      return CURRENT_BRANCH
    end)
    t.eq(resolved, 1)
    t.eq(live.complete, true)
    t.eq(live.set[CURRENT_BRANCH], true)
  end,

  test_live_fix_without_exact_branch_resolution_fails_open = function()
    local live = core.live_branches({
      running_row(333, "review-feedback/head/review-dedup", nil, "fix"),
    }, NOW_MS)
    t.eq(live.complete, false)
  end,

  test_current_rt_without_release_proof_is_skipped = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({ running_row(111, "dedup-orphan") }, NOW_MS)
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT, { released_branches = {} })
    t.eq(removable_has(result, CURRENT_PATH), false)
    t.eq(skip_reason(result, CURRENT_PATH), "current-runtime-release-unverified")
  end,

  test_stable_worktree_without_release_proof_is_skipped = function()
    local worktrees = core.parse_worktrees(porcelain({
      { path = STABLE_PATH, branch = CURRENT_BRANCH },
    }))
    local live = core.live_branches({}, NOW_MS)
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT, { released_branches = {} })
    t.eq(removable_has(result, STABLE_PATH), false)
    t.eq(skip_reason(result, STABLE_PATH), "stable-release-unverified")
  end,

  test_stable_released_worktree_carries_issue_ref_for_fresh_recheck = function()
    local worktrees = core.parse_worktrees(porcelain({
      { path = STABLE_PATH, branch = CURRENT_BRANCH },
    }))
    local live = core.live_branches({}, NOW_MS)
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT, {
      released_branches = {
        [CURRENT_BRANCH] = true,
      },
    })
    t.eq(removable_has(result, STABLE_PATH), true)
    t.eq(result.removable[1].issue_ref.proposal_id, "github-devloop/issue/" .. REPO .. "/333")
  end,

  -- Detached, foreign, and main-checkout worktrees are never removable.
  test_detached_foreign_main_skipped = function()
    local worktrees = core.parse_worktrees(FULL_PORCELAIN)
    local live = core.live_branches({}, NOW_MS)
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT)
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
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT)
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
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT)
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
    local result = core.classify(worktrees, live, CUR_RT, IMPLEMENTATION_ROOT)
    t.eq(removable_has(result, ORPHAN_PATH), false)
    t.eq(skip_reason(result, ORPHAN_PATH), "live-branch")
  end,
}
