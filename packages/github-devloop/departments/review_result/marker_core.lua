local base = require("core")

local M = setmetatable({}, { __index = base })

function M.gh_pr_view_origin(repo, pr_number, timeout)
  return base.fetch_marker_pr_view(repo, pr_number, nil, { consumer = "review_result", force_fresh = true, timeout = timeout })
end

return M
