local devloop_base = require("devloop.base")
local devloop_claims = require("devloop.claims")
local devloop_entity_view = require("devloop.github_proxy_entity_view")
local devloop_logging = require("devloop.logging")
local forge_strings = require("forge.strings")
local github_factory = require("devloop.github_factory")

local M = {}

M.DEPT = "workflow_materialize_next"
M.RELEASE_TIMEOUT_SECONDS = 30

<<<<<<< HEAD
=======
local function owner()
  return devloop_claims.claim_owner()
end

local function is_self_only_assignee(core, ownership, claim_owner)
  local logins = devloop_claims.assignee_logins(ownership and ownership.assignees)
  return #logins == 1
    and forge_strings.canonical_login(logins[1]) == forge_strings.canonical_login(claim_owner)
end

>>>>>>> 64323e14ecdb072282dfe7dec51469d8a77edcd4
local function log(origin, action, reason)
  devloop_logging.log_cas_decision(M.DEPT, origin, { state = nil, version = nil }, "claim", "claim", action, reason)
end

local function github()
  if type(exec_argv) ~= "function" then
    error("github-devloop-workflow: github-adapter-missing-exec-argv: GitHub adapter requires exec_argv")
  end
  return github_factory.production_handle()
end

local function write_enabled(deps)
  if type(deps) == "table" and type(deps.write_enabled) == "function" then
    return deps.write_enabled()
  end
  return devloop_base.read_env("FKST_GITHUB_WRITE") == "1"
end

function M.release_done_claim(core, deps, repo, issue_number, origin)
  if type(deps) == "table" and type(deps.release_done_claim) == "function" then
    return deps.release_done_claim(core, repo, issue_number, origin)
  end

  if type(deps) == "table" and type(deps.release_issue_claim_if_self) == "function" then
    return deps.release_issue_claim_if_self(
      core,
      M.DEPT,
      repo,
      issue_number,
      origin,
      "workflow terminal done"
    )
  end
  return devloop_claims.release_issue_claim_if_self(
    core,
    M.DEPT,
    repo,
    issue_number,
    origin,
    "workflow terminal done"
  )
end

local function issue_close(deps, repo, issue_number)
  if type(deps) == "table" and type(deps.issue_close) == "function" then
    return deps.issue_close(repo, issue_number, { kind = "completed" }, M.RELEASE_TIMEOUT_SECONDS)
  end
  return github().issue_close(repo, issue_number, { kind = "completed" }, M.RELEASE_TIMEOUT_SECONDS)
end

-- A workflow whose every slot genuinely merged is fully implemented, so its origin
-- idea issue is closed: leaving completed origins open clutters the board. Only the
-- "done" terminal reaches here (a "blocked" terminal keeps the issue open for human
-- follow-up). The reconcile skips a non-OPEN origin (discovery skip-closed), so this
-- runs when the issue is open and is not re-attempted once the close is visible.
function M.close_done_origin(core, deps, repo, issue_number, origin)
  if type(deps) == "table" and type(deps.close_done_origin) == "function" then
    return deps.close_done_origin(core, repo, issue_number, origin)
  end

  if not write_enabled(deps) then
    log(origin, "dry-run-close-origin", "terminal done would close the completed origin issue but FKST_GITHUB_WRITE!=1")
    return true
  end

  local result = issue_close(deps, repo, issue_number)
  if type(result) == "table" and result.exit_code ~= nil and result.exit_code ~= 0 then
    error("github-devloop-workflow: workflow-origin-close-failed: workflow origin issue close failed: " .. tostring(result.stderr))
  end
  devloop_entity_view.invalidate_entity_after_write(repo, "issue", issue_number)
  log(origin, "closed-origin", "terminal done closed the completed workflow origin issue")
  return true
end

return M
