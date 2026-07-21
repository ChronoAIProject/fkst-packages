local config = require("devloop.config")
local devloop_base = require("devloop.base")

local M = {}

local function required_host_fact(name, read_env)
  local value = tostring(read_env(name) or ""):gsub("%s+$", "")
  if value == "" then
    error("github-devloop: worktree-local-file-hydration-missing-host-fact: " .. name .. " is required")
  end
  return value
end

function M.hydrate(worktree, dependencies)
  local deps = dependencies or {}
  local read_env = deps.read_env or config.read_env
  local run = deps.run or function(spec)
    return exec_sync(spec)
  end
  local configured = read_env("FKST_WORKTREE_LOCAL_FILES")
  if configured == nil or configured == "" then
    return false
  end

  local host_root = required_host_fact("FKST_HOST_ROOT", read_env)
  local platform_root = required_host_fact("FKST_PLATFORM_ROOT", read_env)
  local script = platform_root:gsub("/+$", "") .. "/scripts/hydrate_worktree_local_files.py"
  local command = "python3 " .. devloop_base._shell_single_quote(script)
    .. " --source-root " .. devloop_base._shell_single_quote(host_root)
    .. " --worktree " .. devloop_base._shell_single_quote(worktree)
  local result = run({ cmd = command, timeout = 60 })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    local stderr = type(result) == "table" and tostring(result.stderr or "") or "invalid command result"
    error("github-devloop: worktree-local-file-hydration-failed: " .. stderr)
  end
  return true
end

return M
