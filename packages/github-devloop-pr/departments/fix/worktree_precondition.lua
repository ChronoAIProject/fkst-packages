local git_adapter = require("forge.git")

local M = {}
local CLEANUP_TIMEOUT_SECONDS = 60

local function production_codex_runs()
  if type(fkst) ~= "table" or type(fkst.codex_runs) ~= "function" then
    error("github-devloop: fix-worktree-owner-check-failed: fkst.codex_runs primitive is required", 0)
  end
  return fkst.codex_runs()
end

local function production_now()
  if type(now) ~= "function" then
    error("github-devloop: fix-worktree-owner-check-failed: now primitive is required", 0)
  end
  return now()
end

local function live_owner(running, proposal_id, now_ms)
  for _, run in ipairs(running) do
    local lease_expires_at_ms = type(run) == "table" and run.lease_expires_at_ms or nil
    local lease_expired = type(lease_expires_at_ms) == "number"
      and lease_expires_at_ms < now_ms
    if type(run) == "table"
      and tostring(run.status or "") == "running"
      and tostring(run.proposal_id or "") == tostring(proposal_id)
      and not lease_expired then
      return run
    end
  end
  return nil
end

function M.make(deps)
  deps = deps or {}
  local git = deps.git
  local codex_runs = deps.codex_runs or production_codex_runs
  local now_seconds = deps.now or production_now

  local function current_owner(proposal_id)
    local ok, snapshot, now_value = pcall(function()
      local current = codex_runs()
      if type(current) ~= "table" or type(current.running) ~= "table" then
        error("github-devloop: fix-worktree-owner-check-failed: fkst.codex_runs returned an invalid running set", 0)
      end
      local current_now = now_seconds()
      if type(current_now) ~= "number" then
        error("github-devloop: fix-worktree-owner-check-failed: now primitive returned a non-number", 0)
      end
      return current, current_now
    end)
    if not ok then
      error("github-devloop: fix-worktree-owner-check-failed: " .. tostring(snapshot), 0)
    end
    return live_owner(snapshot.running, proposal_id, now_value * 1000)
  end

  local function establish(worktree, branch, proposal_id)
    local owner = current_owner(proposal_id)
    if owner ~= nil then
      return false, owner
    end

    local handle = git or git_adapter.production_handle("github-devloop")
    local reset_result = handle.reset_hard_branch(
      worktree, branch, CLEANUP_TIMEOUT_SECONDS)
    if type(reset_result) ~= "table" or reset_result.exit_code ~= 0 then
      error("github-devloop: fix-worktree-reset-failed: git reset --hard failed: exit_code="
        .. tostring(reset_result and reset_result.exit_code)
        .. " stderr=" .. tostring(reset_result and reset_result.stderr), 0)
    end

    local clean_result = handle.clean_fd(worktree, CLEANUP_TIMEOUT_SECONDS)
    if type(clean_result) ~= "table" or clean_result.exit_code ~= 0 then
      error("github-devloop: fix-worktree-clean-failed: git clean -fd failed: exit_code="
        .. tostring(clean_result and clean_result.exit_code)
        .. " stderr=" .. tostring(clean_result and clean_result.stderr), 0)
    end
    return true, nil
  end

  return {
    establish = establish,
  }
end

return M
