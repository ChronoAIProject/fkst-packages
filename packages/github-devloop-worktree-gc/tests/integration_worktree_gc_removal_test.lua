-- End-to-end safety integration: drive the REAL worktree_gc department through its
-- full act path (list -> classify -> pre-remove recheck -> remove) with injected fakes,
-- and prove it removes only unowned deterministic worktrees while preserving live
-- restart orphans and stable worktrees without a lifecycle-owned release fact.

local testing = require("testkit_internal.testing")
local git_fake = require("forge.git_fake")
local github_fake = require("forge.github_fake")
local base = require("devloop.base")
local devloop_state = require("devloop.state")
local marker_builders = require("devloop.markers.builders")
local state_comment = require("testkit_internal.projected_state_fixture").bind_state_comment(devloop_state)
local worktree_gc = require("departments.worktree_gc.main")
local t = fkst.test

local REPO = "ChronoAIProject/fkst-packages"
local OLD_RT = "/runtime/dogfood-rt-packages.1111"
local CUR_RT = "/runtime/dogfood-rt-packages.2222"
local DURABLE_ROOT = "/runtime/dogfood-durable-packages"
local STABLE_ROOT = base.implementation_worktree_root(DURABLE_ROOT)
local NOW_S = 1000000

local ORPHAN_BRANCH = base.implement_branch(REPO, 111, "dedup-orphan")
local TERMINAL_BRANCH = base.implement_branch(REPO, 222, "dedup-terminal")
local STABLE_BRANCH = base.implement_branch(REPO, 333, "dedup-current")

local MAIN_PATH = "/home/dev/fkst-packages"
local ORPHAN_PATH = OLD_RT .. "/worktrees/devloop-orphan-111"
local TERMINAL_PATH = OLD_RT .. "/worktrees/devloop-terminal-222"
local STABLE_PATH = STABLE_ROOT .. "/worktrees/devloop-current-333"
local DETACHED_PATH = OLD_RT .. "/worktrees/devloop-detached-444"
local FOREIGN_PATH = OLD_RT .. "/worktrees/some-other-555"

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

local FULL = porcelain({
  { path = MAIN_PATH, branch = "integration" },
  { path = ORPHAN_PATH, branch = ORPHAN_BRANCH },
  { path = TERMINAL_PATH, branch = TERMINAL_BRANCH },
  { path = STABLE_PATH, branch = STABLE_BRANCH },
  { path = DETACHED_PATH, detached = true },
  { path = FOREIGN_PATH, branch = "feature/some-external-branch" },
})

-- Fake git handle: worktree_list returns the fixture porcelain; worktree_remove records
-- the removed path; worktree_prune is a no-op success.
local function fake_git(removed)
  local git = git_fake.new(git_fake.model({}))
  git._exec = function(argv)
    if argv[2] == "worktree" and argv[3] == "list" then
      return { stdout = FULL, stderr = "", exit_code = 0 }
    elseif argv[2] == "worktree" and argv[3] == "remove" then
      removed[#removed + 1] = argv[5] -- {"git","worktree","remove","--force",<path>}
      return { stdout = "", stderr = "", exit_code = 0 }
    elseif argv[2] == "worktree" and argv[3] == "prune" then
      return { stdout = "", stderr = "", exit_code = 0 }
    end
    return { stdout = "", stderr = "unexpected argv", exit_code = 1 }
  end
  return git
end

local function running_row(issue, dedup, role)
  return {
    role = role,
    status = "running",
    proposal_id = "github-devloop/issue/" .. REPO .. "/" .. tostring(issue),
    dedup_key = dedup,
    lease_expires_at_ms = (NOW_S * 1000) + 600000,
  }
end

local function issue_fixture(issue_number, state_name, lifecycle_marker, state_version)
  local marker_body = state_comment(
    "github-devloop/issue/" .. REPO .. "/" .. tostring(issue_number),
    state_name,
    state_version or "dedup-current"
  )
  if lifecycle_marker ~= nil then
    marker_body = marker_body .. "\n" .. lifecycle_marker
  end
  return {
    number = issue_number,
    title = "fixture",
    state = state_name == "merged" and "CLOSED" or "OPEN",
    comments = {
      {
        id = tostring(issue_number) .. "001",
        body = marker_body,
        author = { login = base._test_bot_login },
        createdAt = "2026-07-22T00:01:00Z",
      },
    },
  }
end

local function fake_github(issue_state, lifecycle_marker, state_version)
  local issues = {}
  if issue_state ~= nil then
    issues[REPO .. "#issue/333"] = issue_fixture(
      333, issue_state, lifecycle_marker, state_version)
  end
  return github_fake.new(github_fake.model({ issues = issues }))
end

local function sequenced_github(snapshots, reads)
  return {
    read_issue = function(source_ref)
      reads.count = reads.count + 1
      local snapshot = snapshots[math.min(reads.count, #snapshots)]
      return fake_github(snapshot.state, snapshot.marker).read_issue(source_ref)
    end,
  }
end

local function department_with(
    removed, running_rows, remove_env, issue_state, lifecycle_marker, github_override, state_version)
  return worktree_gc.make_department({
    git = fake_git(removed),
    github = github_override or fake_github(issue_state, lifecycle_marker, state_version),
    read_env = function(name)
      if name == "FKST_RUNTIME_ROOT" then
        return CUR_RT
      elseif name == "FKST_DURABLE_ROOT" then
        return DURABLE_ROOT
      elseif name == "FKST_WORKTREE_GC_REMOVE" then
        return remove_env
      end
      return nil
    end,
    now = function()
      return NOW_S
    end,
    codex_runs = type(running_rows) == "function" and running_rows or function()
      return { running = running_rows, recent = {} }
    end,
  })
end

local function implementation_marker()
  return marker_builders.implementing_marker(
    "github-devloop/issue/" .. REPO .. "/333",
    "dedup-current",
    STABLE_BRANCH,
    "1111111111111111111111111111111111111111",
    "dev",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  )
end

local function checkpoint_marker()
  return marker_builders.implement_checkpoint_marker(
    "github-devloop/issue/" .. REPO .. "/333",
    "dedup-current",
    STABLE_BRANCH,
    "1111111111111111111111111111111111111111",
    "dev",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    1
  )
end

local function failure_marker()
  return '<!-- fkst:github-devloop:impl-failure:v1 proposal="github-devloop/issue/'
    .. REPO .. '/333" reason="local-iteration-failed" attempt="1" dedup="dedup-current" -->'
end

local function tick()
  return {
    queue = "github-devloop-worktree-gc.worktree_gc_tick",
    ts = "2026-07-22T00:00:00Z",
    payload = {
      schema = "github-devloop-worktree-gc.gc-tick.v1",
      source_ref = { kind = "cron", ref = "github-devloop-worktree-gc/worktree_gc_poll/tick" },
    },
  }
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

return {
  -- The orphan (live codex row) is kept; the terminal old-RT worktree is removed;
  -- the nonterminal stable worktree, detached, foreign, and main checkout are never removed.
  test_removes_only_terminal_old_rt_worktree = function()
    local removed = {}
    local dept = department_with(removed, { running_row(111, "dedup-orphan") }, "1", "ready")
    testing.run_fake(dept, tick())

    t.eq(#removed, 1)
    t.eq(removed[1], TERMINAL_PATH)
    t.eq(contains(removed, ORPHAN_PATH), false)
    t.eq(contains(removed, STABLE_PATH), false)
    t.eq(contains(removed, DETACHED_PATH), false)
    t.eq(contains(removed, FOREIGN_PATH), false)
    t.eq(contains(removed, MAIN_PATH), false)
  end,

  -- Dry-run posture (FKST_WORKTREE_GC_REMOVE unset): the sweep identifies the same
  -- removable candidate but mutates NOTHING (it only logs `would-remove`).
  test_dry_run_removes_nothing = function()
    local removed = {}
    local dept = department_with(removed, { running_row(111, "dedup-orphan") }, nil, "merged")
    testing.run_fake(dept, tick())
    t.eq(#removed, 0)
  end,

  -- Fail-open: an unparseable LIVE running row makes the live set incomplete, so even
  -- with removal ENABLED the department removes NOTHING this pass.
  test_fail_open_removes_nothing_on_unparseable_running_row = function()
    local removed = {}
    local rows = {
      running_row(111, "dedup-orphan"),
      { status = "running", proposal_id = "unparseable", dedup_key = "x", lease_expires_at_ms = (NOW_S * 1000) + 600000 },
    }
    local dept = department_with(removed, rows, "1", "merged")
    testing.run_fake(dept, tick())
    t.eq(#removed, 0)
  end,

  -- A stable deterministic worktree is removed only when the issue stream has
  -- a fresh trusted terminal marker and codex_runs proves the branch is not live.
  test_removes_stable_terminal_worktree = function()
    local removed = {}
    local dept = department_with(removed, { running_row(111, "dedup-orphan") }, "1", "merged")
    testing.run_fake(dept, tick())

    t.eq(#removed, 2)
    t.eq(contains(removed, TERMINAL_PATH), true)
    t.eq(contains(removed, STABLE_PATH), true)
    t.eq(contains(removed, ORPHAN_PATH), false)
  end,

  -- A stable deterministic worktree with a nonterminal trusted marker is kept
  -- even when no codex row is live.
  test_keeps_stable_nonterminal_worktree = function()
    local removed = {}
    local dept = department_with(removed, { running_row(111, "dedup-orphan") }, "1", "implementing")
    testing.run_fake(dept, tick())

    t.eq(#removed, 1)
    t.eq(removed[1], TERMINAL_PATH)
    t.eq(contains(removed, STABLE_PATH), false)
  end,

  test_live_retry_worktree_survives_terminal_marker_race = function()
    local removed = {}
    local dept = department_with(removed, {
      running_row(333, "dedup-current/reimplement/2"),
    }, "1", "merged")
    testing.run_fake(dept, tick())

    t.eq(contains(removed, STABLE_PATH), false)
  end,

  test_published_stable_worktree_remains_owned_without_live_row_during_fix_harvest = function()
    local release_marker = implementation_marker()
    local removed = {}
    local dept = department_with(removed, {}, "1", "implementing", release_marker)
    testing.run_fake(dept, tick())

    t.eq(contains(removed, STABLE_PATH), false)
  end,

  test_preserves_published_branch_reacquired_by_live_fix = function()
    local release_marker = implementation_marker()
    local reads = 0
    local removed = {}
    local dept = department_with(removed, function()
      reads = reads + 1
      local running = reads == 1 and {} or {
        running_row(333, "review-feedback/head/review-dedup", "fix"),
      }
      return { running = running, recent = {} }
    end, "1", "implementing", release_marker)

    testing.run_fake(dept, tick())

    t.eq(reads >= 2, true)
    t.eq(contains(removed, STABLE_PATH), false)
  end,

  test_retry_harvest_keeps_stable_worktree_despite_stale_checkpoint = function()
    local removed = {}
    local dept = department_with(
      removed,
      {},
      "1",
      "implementing",
      checkpoint_marker(),
      nil,
      "dedup-current/reimplement/2"
    )
    testing.run_fake(dept, tick())

    t.eq(contains(removed, STABLE_PATH), false)
  end,

  test_stale_impl_failed_does_not_release_reentered_worktree_during_harvest = function()
    local removed = {}
    local dept = department_with(removed, {}, "1", "impl-failed", failure_marker())
    testing.run_fake(dept, tick())

    t.eq(contains(removed, STABLE_PATH), false)
  end,

  test_preserves_candidate_when_release_fact_vanishes_before_remove = function()
    local removed = {}
    local reads = { count = 0 }
    local github = sequenced_github({
      { state = "merged", marker = nil },
      { state = "implementing", marker = nil },
    }, reads)
    local dept = department_with(removed, {}, "1", nil, nil, github)
    testing.run_fake(dept, tick())

    t.eq(reads.count >= 2, true)
    t.eq(contains(removed, STABLE_PATH), false)
  end,
}
