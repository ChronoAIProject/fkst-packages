-- github-devloop-dev-intake: the single binding table.
--
-- This is the label-scoped replacement for github-devloop-intake's poll-all admission in
-- the workflow-dev topology. On a cron tick it discovers OPEN fkst-dev issues via the
-- shared github-issue label discovery, then for each one runs the SAME per-issue admission
-- sequence github-devloop-intake/departments/admission/main.lua runs -- fetch rich intake
-- view -> parse -> skip-guard -> claim -> build candidate -> raise -- reusing the shared
-- claim (devloop.claims.claim_issue_for_management) and candidate builder
-- (devloop.payloads.builders via dev_intake) VERBATIM, and emitting the EXISTING candidate
-- seam github-devloop-intake.devloop_intake_candidate that github-devloop-workflow's
-- workflow_select already consumes.
--
-- The orchestration + the core-threaded reuse points live HERE (a package-root binding),
-- not under departments/, so the thin department wrappers carry no require("core") /
-- core.X reads. It requires the shared kernel modules by their bare devloop names and the
-- adapter's own modules (core, dev_intake) by their package-root names.
local strings = require("contract.strings")
local env = require("workflow.env")
local github_factory = require("devloop.github_factory")
local devloop_commands = require("devloop.commands")
local devloop_logging = require("devloop.logging")
local parsers_issue = require("devloop.parsers.issue")
local m_claims = require("devloop.claims")
local scopes = require("github-issue.scopes")
local core = require("core")
local dev_intake = require("dev_intake")

local DEPT = "dev_select"
local INTAKE_JUDGE_FIELDS = "title,body,createdAt,updatedAt,labels,comments,state,assignees,author"

local function env_command(name)
  return 'printf %s "$' .. name .. '"'
end

local function read_env(name)
  local ok, value = pcall(env.read_env, name, exec_sync, env_command)
  if not ok or type(value) ~= "string" then
    return nil
  end
  return strings.trim(value)
end

local function github_handle()
  local ok, handle = pcall(github_factory.production_handle)
  if not ok then
    return nil
  end
  return handle
end

local M = {}

function M.repo()
  return read_env("FKST_GITHUB_REPO") or ""
end

function M.bot_login()
  return read_env("FKST_GITHUB_BOT_LOGIN") or ""
end

function M.github()
  return github_handle()
end

-- Fetch the rich intake-judge view for one discovered issue and parse it exactly as
-- github-devloop-intake admission does (same fields, same parser, same core passed for
-- signature parity).
local function read_current_issue(repo, issue_number)
  local view = devloop_commands.gh_issue_view(repo, issue_number, INTAKE_JUDGE_FIELDS, 30)
  if type(view) ~= "table" or view.exit_code ~= 0 then
    error("github-devloop-dev-intake: gh-issue-dev-view-failed: gh issue dev-intake view failed: " .. tostring(view and view.stderr))
  end
  local current = parsers_issue.parse_issue_view_intake_judge(core, view.stdout)
  current.number = issue_number
  return current
end

-- The per-tick orchestration: discover the fkst-dev scopes, then admit each via the shared
-- claim + candidate builder. NEVER touches a sibling package's issues -- discovery is
-- pinned to the fkst-dev label.
local function admit_tick()
  local repo = M.repo()
  local discovered = scopes.list({
    github = M.github(),
    repo = repo,
    label = dev_intake.LABEL,
    bot_login = M.bot_login(),
  })
  dev_intake.admit_scopes({
    core = core,
    dept = DEPT,
    repo = repo,
    scopes = discovered,
    read_current = function(number)
      return read_current_issue(repo, tostring(number))
    end,
    claim = m_claims.claim_issue_for_management,
    emit = devloop_logging.log_raise,
  })
end

-- The saga handler set for the dev_select department (the cron-tick consumer). done is
-- cheap/side-effect-free; act runs the discovery + admission; wrap gives the standard
-- devloop pipeline-failure fact.
function M.dev_select_handlers()
  return {
    name = DEPT,
    done = function(_event)
      return false
    end,
    act = function(_event)
      admit_tick()
    end,
    wrap = devloop_logging.wrap_pipeline_failure,
  }
end

return M
