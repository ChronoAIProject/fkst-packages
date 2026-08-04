local child_disposition = require("child_disposition")
local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow_child_disposition_request" },
  published_seam = { "workflow_child_disposition_request" },
  produces = { "github-proxy.github_issue_comment_request" },
  stall_window = "30s",
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
}

return saga.department(spec, child_disposition.request_handlers())
