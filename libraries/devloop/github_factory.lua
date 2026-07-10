local github_adapter = require("forge.github")
local github_author_policy = require("devloop.github_author_policy")

local M = {}
local production_exec_argv = type(exec_argv) == "function" and exec_argv or nil
local production_exec_sync = type(exec_sync) == "function" and exec_sync or nil

-- Single production GitHub capability provider — Step 1 of
-- docs/superpowers/specs/2026-07-09-github-egress-capability-refactor.md; all
-- production gh handle construction routes here.
local production_handle = nil

function M.github_options(exec)
  return github_author_policy.github_options(exec)
end

function M.new(exec, env_exec)
  if type(exec) ~= "function" then
    error("github-devloop: GitHub adapter requires an exec function")
  end
  return github_adapter.new(exec, M.github_options(env_exec))
end

function M.production_handle()
  if production_handle == nil then
    if production_exec_argv == nil then
      error("github-devloop: GitHub adapter requires exec_argv")
    end
    if production_exec_sync == nil then
      error("github-devloop: GitHub adapter requires exec_sync for author policy")
    end
    production_handle = github_adapter.new(production_exec_argv, M.github_options(production_exec_sync))
  end
  return production_handle
end

return M
