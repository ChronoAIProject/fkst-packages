local child_disposition = require("child_disposition")
local saga = require("workflow.saga")

local spec = {
  consumes = { "github-proxy.github_comment_written" },
  produces = {},
  fanout = { "github-proxy.github_comment_written" },
  stall_window = "30s",
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}

return saga.department(spec, child_disposition.handoff_handlers())
