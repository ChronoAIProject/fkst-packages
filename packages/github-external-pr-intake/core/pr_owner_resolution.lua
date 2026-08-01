local core = require("core")
local claims = require("devloop.claims")

local M = {}

local backing_issue_view_fields = "number,state,labels,assignees,author"

local function has_actionable_issue_origin(github, pr)
  local origin = core.find_current_issue_pr_origin(pr)
  if origin == nil then
    return false
  end
  local result = github.issue_view(origin.repo, origin.issue_number, backing_issue_view_fields, 30)
  local decoded = core.decode_json_object(result and result.stdout or "{}", "backing issue view")
  decoded.number = decoded.number or origin.issue_number
  local issue = core.normalize_issue(decoded)
  return claims.is_self_owned_issue(issue, claims.claim_owner())
end

function M.classify(github, pr, managed, branches)
  return core.classify_pr_owner(
    pr,
    managed,
    branches,
    github.is_authorized_author(pr.author_login),
    has_actionable_issue_origin(github, pr)
  )
end

return M
