local core = require("core")
local pr_owner_resolution = require("core.pr_owner_resolution")

return {
  classify = pr_owner_resolution.classify,
  branches = core.pr_owner_branches,
  find_disposition_marker = core.find_pr_disposition_marker,
  is_bridge_age_eligible = core.is_bridge_age_eligible,
  retirement_comment_body = core.pr_retirement_comment_body,
}
