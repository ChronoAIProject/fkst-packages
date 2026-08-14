local M = {}
local PROTOCOL = "FKST_IMPLEMENTATION_WORKTREE_SINGLEFLIGHT:v1"
local HELPER_ENV = "FKST_IMPLEMENTATION_WORKTREE_SINGLEFLIGHT_HELPER"
local guardian_script = require("departments.implement.worktree_singleflight_helper")

local function lock_path(worktree)
  local path = tostring(worktree or "")
  if path == "" or path:find("[\r\n]") ~= nil or path:sub(1, 1) ~= "/" then
    error("github-devloop: implementation-worktree-singleflight-path-invalid: worktree path must be absolute")
  end
  return path:gsub("/+$", "") .. ".local-iteration-singleflight.lock"
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command(action, worktree, token, owner_pid)
  local owner_argument = owner_pid == nil and '"$PPID"' or shell_quote(tostring(owner_pid))
  return '"${FKST_PYTHON:-python3}" -c '
    .. shell_quote('import os; exec(os.environ["' .. HELPER_ENV .. '"])')
    .. " " .. shell_quote(action)
    .. " " .. shell_quote(lock_path(worktree))
    .. " " .. shell_quote(token or "")
    .. " " .. owner_argument
end

local function parse_result(action, result)
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("github-devloop: implementation-worktree-singleflight-command-failed: " .. action .. ": "
      .. tostring(type(result) == "table" and result.stderr or "missing command result"), 0)
  end
  local line = tostring(result.stdout or ""):gsub("[\r\n]+$", "")
  local status, value = line:match("^" .. PROTOCOL .. ":([A-Z]+):([^\r\n]+)$")
  if value == nil then
    error("github-devloop: implementation-worktree-singleflight-command-failed: "
      .. action .. ": helper returned a malformed result", 0)
  end
  return status, value
end

local function acquire(exec, worktree, owner_pid)
  local status, value = parse_result("acquire", exec({
    cmd = command("acquire", worktree, "", owner_pid),
    env = { [HELPER_ENV] = guardian_script },
    timeout = 30,
  }))
  if status == "BUSY" and value == "locked" then
    return nil
  end
  if status ~= "ACQUIRED" or value:match("^[0-9a-f]+$") == nil then
    error("github-devloop: implementation-worktree-singleflight-acquire-failed: helper returned an invalid status", 0)
  end
  return value
end

function M.make(deps)
  deps = deps or {}
  local exec = deps.exec or exec_sync
  if type(exec) ~= "function" then
    error("github-devloop: implementation-worktree-singleflight-exec-missing: exec_sync is required")
  end

  local function release(worktree, token)
    local status, value = parse_result("release", exec({
      cmd = command("release", worktree, token),
      env = { [HELPER_ENV] = guardian_script },
      timeout = 30,
    }))
    if status ~= "RELEASED" or value ~= token then
      error("github-devloop: implementation-worktree-singleflight-release-failed: helper returned an invalid status", 0)
    end
  end

  local function with_lock(worktree, fn)
    local token = acquire(exec, worktree)
    if token == nil then
      return false
    end
    local ok, result = pcall(fn)
    local released, release_error = pcall(release, worktree, token)
    if not ok then
      if not released then
        error(tostring(result) .. "\nworktree single-flight release failed: " .. tostring(release_error), 0)
      end
      error(result, 0)
    end
    if not released then
      error(release_error, 0)
    end
    return true, result
  end

  return {
    acquire = function(worktree) return acquire(exec, worktree) end,
    release = release,
    with_lock = with_lock,
  }
end

function M._acquire_for_owner(worktree, owner_pid, exec)
  if tostring(owner_pid or ""):match("^%d+$") == nil then
    error("github-devloop: implementation-worktree-singleflight-owner-invalid: owner pid must be numeric")
  end
  return acquire(exec, worktree, tonumber(owner_pid))
end

M.lock_path = lock_path

return M
