-- End-to-end safety integration: drive the REAL worktree_gc department through its
-- full act path (list -> classify -> pre-remove recheck -> remove) with injected fakes,
-- and prove it removes ONLY the terminal old-RT deterministic worktree while keeping the
-- orphan-after-restart worktree and skipping current-RT / detached / foreign ones.

local testing = require("testkit_internal.testing")
local git_fake = require("forge.git_fake")
local base = require("devloop.base")
local worktree_gc = require("departments.worktree_gc.main")
local t = fkst.test

local REPO = "ChronoAIProject/fkst-packages"
local OLD_RT = "/runtime/dogfood-rt-packages.1111"
local CUR_RT = "/runtime/dogfood-rt-packages.2222"
local NOW_S = 1000000

local ORPHAN_BRANCH = base.implement_branch(REPO, 111, "dedup-orphan")
local TERMINAL_BRANCH = base.implement_branch(REPO, 222, "dedup-terminal")
local CURRENT_BRANCH = base.implement_branch(REPO, 333, "dedup-current")

local MAIN_PATH = "/home/dev/fkst-packages"
local ORPHAN_PATH = OLD_RT .. "/worktrees/devloop-orphan-111"
local TERMINAL_PATH = OLD_RT .. "/worktrees/devloop-terminal-222"
local CURRENT_PATH = CUR_RT .. "/worktrees/devloop-current-333"
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
  { path = CURRENT_PATH, branch = CURRENT_BRANCH },
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

local function running_row(issue, dedup)
  return {
    status = "running",
    proposal_id = "github-devloop/issue/" .. REPO .. "/" .. tostring(issue),
    dedup_key = dedup,
    lease_expires_at_ms = (NOW_S * 1000) + 600000,
  }
end

local function department_with(removed, running_rows, remove_env)
  return worktree_gc.make_department({
    git = fake_git(removed),
    read_env = function(name)
      if name == "FKST_RUNTIME_ROOT" then
        return CUR_RT
      elseif name == "FKST_WORKTREE_GC_REMOVE" then
        return remove_env
      end
      return nil
    end,
    now = function()
      return NOW_S
    end,
    codex_runs = function()
      return { running = running_rows, recent = {} }
    end,
  })
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
  -- current-RT, detached, foreign, and the main checkout are never removed.
  test_removes_only_terminal_old_rt_worktree = function()
    local removed = {}
    local dept = department_with(removed, { running_row(111, "dedup-orphan") }, "1")
    testing.run_fake(dept, tick())

    t.eq(#removed, 1)
    t.eq(removed[1], TERMINAL_PATH)
    t.eq(contains(removed, ORPHAN_PATH), false)
    t.eq(contains(removed, CURRENT_PATH), false)
    t.eq(contains(removed, DETACHED_PATH), false)
    t.eq(contains(removed, FOREIGN_PATH), false)
    t.eq(contains(removed, MAIN_PATH), false)
  end,

  -- Dry-run posture (FKST_WORKTREE_GC_REMOVE unset): the sweep identifies the same
  -- removable candidate but mutates NOTHING (it only logs `would-remove`).
  test_dry_run_removes_nothing = function()
    local removed = {}
    local dept = department_with(removed, { running_row(111, "dedup-orphan") }, nil)
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
    local dept = department_with(removed, rows, "1")
    testing.run_fake(dept, tick())
    t.eq(#removed, 0)
  end,
}
