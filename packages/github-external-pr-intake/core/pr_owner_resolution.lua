local core = require("core")
local forge_strings = require("forge.strings")
local env = require("workflow_internal.env")

local M = {}

local backing_issue_view_fields = "number,state,labels,assignees,author"
local read_env = env.read_env(function(name)
  if name ~= "FKST_GITHUB_CLAIM_MODE" then
    error("github-external-pr-intake: env-not-allowed: " .. tostring(name))
  end
  return 'printf %s "$FKST_GITHUB_CLAIM_MODE"'
end)

local function contains(values, expected)
  for _, value in ipairs(values or {}) do
    if tostring(value) == tostring(expected) then
      return true
    end
  end
  return false
end

local function issue_is_self_owned(issue)
  if tostring(read_env("FKST_GITHUB_CLAIM_MODE") or "") == "label" then
    return contains(issue.labels, "fkst-dev:claimed")
  end
  local owner = core.current_bot_login()
  if #(issue.assignees or {}) == 1
    and forge_strings.strip_bot_login_suffix(issue.assignees[1]) == owner then
    return true
  end
  if #(issue.assignees or {}) > 0 then
    return false
  end
  return forge_strings.strip_bot_login_suffix(issue.author_login) == owner
end

local function has_actionable_issue_origin(github, pr, managed)
  local origin = core.find_current_issue_pr_origin(pr, managed)
  if origin == nil then
    return false
  end
  local result = github.issue_view(origin.repo, origin.issue_number, backing_issue_view_fields, 30)
  local decoded = core.decode_json_object(result and result.stdout or "{}", "backing issue view")
  decoded.number = decoded.number or origin.issue_number
  local issue = core.normalize_issue(decoded)
  return issue_is_self_owned(issue)
end

function M.classify(github, pr, managed, branches)
  return core.classify_pr_owner(
    pr,
    managed,
    branches,
    github.is_authorized_author(pr.author_login),
    has_actionable_issue_origin(github, pr, managed)
  )
end

return M
