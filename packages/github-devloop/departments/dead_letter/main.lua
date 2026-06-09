local core = require("core")

local M = {}

M.spec = {
  consumes = { "github-devloop.dead_letter" },
  produces = {
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_pr_comment_request",
  },
  stall_window = "2m",
}

function pipeline(event)
  core.handle_dead_letter(event)
end

return M
