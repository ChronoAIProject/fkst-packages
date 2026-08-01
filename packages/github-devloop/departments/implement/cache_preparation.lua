local config = require("devloop.config")
local strings = require("contract.strings")

local M = {}

local cache_preparation_timeout_seconds = 600
local trusted_repository_root = "."

local function command_detail(result)
  if type(result) ~= "table" then
    return "command returned no result"
  end
  local detail = strings.trim(result.stderr or "")
  if detail == "" then
    detail = strings.trim(result.stdout or "")
  end
  local exit_code = tostring(result.exit_code or "unknown")
  if detail == "" then
    return "exit_code=" .. exit_code
  end
  return "exit_code=" .. exit_code .. ": " .. detail
end

function M.run(worktree, deps)
  local options = deps or {}
  local read_command = options.command or config.cache_preparation_command
  local command = strings.trim(read_command() or "")
  if command == "" then
    return false
  end

  local execute = options.exec or exec_sync
  if type(execute) ~= "function" then
    error("github-devloop: cache-preparation-unavailable: exec_sync is unavailable")
  end
  local result = execute({
    cmd = command,
    -- Department children run with the trusted supervisor project root as ".".
    cwd = trusted_repository_root,
    env = {
      FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE = worktree,
    },
    timeout = cache_preparation_timeout_seconds,
  })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("github-devloop: cache-preparation-failed: " .. command_detail(result))
  end
  return true
end

return M
