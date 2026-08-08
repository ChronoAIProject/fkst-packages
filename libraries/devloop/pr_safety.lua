local C = {}
local forge_validators = require("devloop.forge_validators")

function C.is_safe_branch(branch)
  return forge_validators.is_git_ref_safe(branch)
end

function C.is_devloop_issue_branch(branch)
  return type(branch) == "string"
    and forge_validators.is_git_ref_safe(branch)
    and branch:find("^devloop/issue/[^/]+/.+/.+") ~= nil
end

function C.is_safe_head_sha(head_sha)
  return forge_validators.is_git_sha(head_sha)
end

function C.is_safe_pr_number(pr_number)
  return forge_validators.is_positive_pr_number(pr_number)
end

function C.origin_matches_pr(origin, current_pr, repo, integration_branch, require_issue_backing)
  if origin.repo ~= repo then
    return false, "repo"
  end
  if require_issue_backing and origin.issue_number == nil then
    return false, "issue"
  end
  if tostring(current_pr.head_ref_name or "") ~= tostring(origin.branch) then
    return false, "head"
  end
  if tostring(current_pr.base_ref_name or "") ~= tostring(origin.base_branch) then
    return false, "base"
  end
  if origin.base_branch ~= nil
    and tostring(origin.base_branch or "") ~= tostring(integration_branch) then
    return false, "base"
  end
  return true, "ok"
end

function C.origin_base_matches_current_pr(origin, current_pr)
  return tostring(current_pr.base_ref_name or "") == tostring(origin.base_branch)
end

function C.origin_base_matches_integration(origin, integration_branch)
  return origin.base_branch ~= nil
    and tostring(origin.base_branch or "") == tostring(integration_branch)
end

return C
