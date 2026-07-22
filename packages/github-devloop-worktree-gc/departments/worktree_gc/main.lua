-- worktree_gc: level-triggered, stateless, fail-open sweep that removes EXPIRED
-- deterministic github-devloop worktrees. "Expired" = proven not-live by the
-- ground-truth codex-run -> implement_branch join (never age). v1 scope is
-- old-runtime-root (restart-orphaned) worktrees only, which is the primary
-- "registry leak #500" and is structurally free of the creation race.
--
-- Safety: nothing is removed unless core.classify proves it, and each candidate is
-- re-validated against a FRESH codex_runs snapshot immediately before removal
-- (TOCTOU guard). Any error, empty runtime root, or incomplete live set fails OPEN
-- (skip this tick, retry next). Non-deterministic/detached/current-RT worktrees are
-- skipped and never force-removed — those need an engine primitive that exposes the
-- running codex's worktree path (a separate fkst-substrate change).

local env = require("workflow_internal.env")
local error_facts = require("contract.error_facts")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")
local caps = require("worktree_gc_caps")

local spec = {
  consumes = { "worktree_gc_tick" },
  produces = {},
  stall_window = "30s",
}

local allowed_env = {
  FKST_RUNTIME_ROOT = true,
  -- Dangerous-posture host fact (same shape as FKST_GITHUB_WRITE): real worktree
  -- removal only happens when this is "1". Unset/anything-else = DRY-RUN: the sweep
  -- logs each `would-remove` it identified but mutates nothing. This lets the GC run
  -- live and be observed before it is trusted to delete.
  FKST_WORKTREE_GC_REMOVE = true,
}

local function read_env_command(name)
  if not allowed_env[name] then
    error("github-devloop-worktree-gc: env-name-denied: " .. tostring(name), 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local production_read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

local function production_now()
  if type(now) ~= "function" then
    error("github-devloop-worktree-gc: now-unavailable: now primitive is required", 0)
  end
  return now()
end

local function production_codex_runs()
  if type(fkst) ~= "table" or type(fkst.codex_runs) ~= "function" then
    error("github-devloop-worktree-gc: codex-runs-unavailable: fkst.codex_runs primitive is required", 0)
  end
  return fkst.codex_runs()
end

local function is_gc_tick(event)
  local queue = tostring(event and event.queue or "")
  return queue == "worktree_gc_tick" or queue == "github-devloop-worktree-gc.worktree_gc_tick"
end

local function gc_log(outcome, fields)
  fields = fields or {}
  table.insert(fields, 1, "tag=WORKTREE_GC")
  table.insert(fields, 2, "outcome=" .. tostring(outcome))
  log.info("github-devloop-worktree-gc dept=worktree_gc " .. table.concat(fields, " "))
end

local function wrap_pipeline_failure(dept, fn)
  return function(event)
    local ok, result = pcall(fn, event)
    if ok then
      return result
    end
    local fields = error_facts.error_fact_fields("caught-failure", type(event) == "table" and event.queue or nil, dept, result, {
      source_ref = error_facts.event_source_ref(event),
    })
    table.insert(fields, "error=" .. error_facts.one_line(result))
    log["error"]("github-devloop-worktree-gc dept=" .. dept .. " tag=FAILURE " .. table.concat(fields, " "))
    error("github-devloop-worktree-gc: caught-failure: " .. tostring(result), 0)
  end
end

local function gc_done(event)
  if not is_gc_tick(event) then
    error("github-devloop-worktree-gc: unknown-queue: " .. tostring(event and event.queue), 0)
  end
  return false
end

local function make_department(ports)
  ports = ports or {}
  local git = ports.git
  local read_env = ports.read_env or production_read_env
  local now_value = ports.now or production_now
  local codex_runs = ports.codex_runs or production_codex_runs

  -- Snapshot the live deterministic-branch set from a fresh codex_runs read.
  -- Returns the { set, complete } table, or nil on any read error (fail-open).
  local function snapshot_live()
    local ok, runs = pcall(codex_runs)
    if not ok or type(runs) ~= "table" then
      return nil
    end
    local now_ms = now_value() * 1000
    return caps.live_branches(runs.running or {}, now_ms)
  end

  local function act_gc(event)
    if not is_gc_tick(event) then
      error("github-devloop-worktree-gc: unknown-queue: " .. tostring(event and event.queue), 0)
    end

    -- Dangerous-posture host fact: real removal only when FKST_WORKTREE_GC_REMOVE=1.
    local remove_enabled = tostring(read_env("FKST_WORKTREE_GC_REMOVE") or "") == "1"

    -- (1) current runtime root — required to distinguish old-RT (removable) from current-RT (kept).
    local current_rt = tostring(read_env("FKST_RUNTIME_ROOT") or "")
    if current_rt == "" then
      gc_log("skip-no-runtime-root", {})
      return
    end

    -- (2) enumerate every registered worktree (all runtime roots, this clone only).
    local list = git.worktree_list(30)
    if type(list) ~= "table" or list.exit_code ~= 0 then
      gc_log("skip-worktree-list-failed", { "exit_code=" .. tostring(list and list.exit_code) })
      return
    end
    local worktrees = caps.parse_worktrees(list.stdout)

    -- (3) live set from ground-truth codex_runs; fail-open on any read error.
    local live = snapshot_live()
    if live == nil then
      gc_log("skip-codex-runs-failed", {})
      return
    end

    -- (4) classify. Removable = deterministic devloop branch, not live, old-RT.
    local result = caps.classify(worktrees, live, current_rt)
    gc_log("scanned", {
      "worktrees=" .. tostring(#worktrees),
      "removable=" .. tostring(#result.removable),
      "skipped=" .. tostring(#result.skipped),
      "live_complete=" .. tostring(live.complete),
    })

    -- (5) remove each candidate, re-validating against a FRESH codex_runs snapshot
    --     immediately before the destructive op (TOCTOU guard). Fail-open per item.
    for _, candidate in ipairs(result.removable) do
      local recheck = snapshot_live()
      if recheck == nil or not recheck.complete then
        gc_log("skip-recheck-indeterminate", { "branch=" .. tostring(candidate.branch), "path=" .. tostring(candidate.path) })
      elseif recheck.set[candidate.branch] then
        gc_log("skip-raced-now-live", { "branch=" .. tostring(candidate.branch), "path=" .. tostring(candidate.path) })
      elseif not remove_enabled then
        gc_log("would-remove-dry-run", { "branch=" .. tostring(candidate.branch), "path=" .. tostring(candidate.path) })
      else
        local ok, removed = pcall(function()
          return git.worktree_remove(candidate.path, 60)
        end)
        if ok and type(removed) == "table" and removed.exit_code == 0 then
          gc_log("removed", { "branch=" .. tostring(candidate.branch), "path=" .. tostring(candidate.path) })
        else
          gc_log("remove-failed", {
            "branch=" .. tostring(candidate.branch),
            "path=" .. tostring(candidate.path),
            "exit_code=" .. tostring(type(removed) == "table" and removed.exit_code or "error"),
          })
        end
      end
    end

    -- (6) prune registry-dangling entries (worktree dirs already gone). Best-effort.
    local pruned_ok = pcall(function()
      return git.worktree_prune(30)
    end)
    if not pruned_ok then
      gc_log("prune-failed", {})
    end
  end

  local department = saga.department(spec, {
    done = gc_done,
    act = act_gc,
    wrap = wrap_pipeline_failure,
    name = "worktree_gc",
  })
  department.ports = ports
  return department
end

return ports_lib.install(make_department)
