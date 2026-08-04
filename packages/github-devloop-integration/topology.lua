local error_facts = require("contract.error_facts")
local git_mechanics = require("devloop.git_mechanics")

local T = {}
local shared = git_mechanics.helpers({})

local missing_integration_reason = "missing-integration-branch"

local function is_missing_remote_ref(result)
  local text = tostring(result and result.stderr or "")
  return text:find("couldn't find remote ref", 1, true) ~= nil
end

local function fetch_or_hold(git, branch, args, log_missing_integration)
  local branches = args.branches or {}
  local safe_branch = shared.require_safe_branch("fetch branch", branch)
  local result = git.fetch_branch("origin", safe_branch, 60)
  if result.exit_code == 0 then
    return true
  end
  if safe_branch == branches.integration and is_missing_remote_ref(result) then
    log_missing_integration(args, result)
    return false
  end
  error("github-devloop: branch-fetch-failed: " .. tostring(args.error_class or "branch fetch") .. " failed: " .. tostring(result.stderr))
end

function T.integration_topology_available(args)
  args = args or {}
  local devloop_logging = require("devloop.logging")
  local git = args.git
  local branches = args.branches or {}
  if git == nil then
    error("github-devloop: topology-git-missing: integration topology check requires a git handle")
  end
  if branches.integration == branches.upstream then
    return true
  end

  local function log_missing_integration(args, result)
    local branches = args.branches or {}
    devloop_logging.log_line("info", args.department, args.domain, "HOLD", {
      "repo=" .. tostring(args.repo),
      "upstream=" .. tostring(branches.upstream),
      "integration=" .. tostring(branches.integration),
      "reason=" .. missing_integration_reason,
      "action=seed integration branch from upstream before launch",
      "detail=" .. error_facts.one_line(result and result.stderr or ""),
    })
  end

  return git_mechanics.with_repo_ref_store_lock(args.repo, function()
    if args.fetch_upstream then
      if not fetch_or_hold(git, branches.upstream, args, log_missing_integration) then
        return false
      end
    end
    return fetch_or_hold(git, branches.integration, args, log_missing_integration)
  end)
end

return T
