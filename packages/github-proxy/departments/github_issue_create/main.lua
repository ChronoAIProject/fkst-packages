local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "github_issue_create_request" },
  produces = { "github_issue_blocked_by_request" },
  stall_window = "30s",
}

local function act(event)
  core.write_issue_create_request(event.payload or {})
end

return saga.department{
  consumes = spec.consumes,
  produces = spec.produces,
  fanout = spec.fanout,
  stall_window = spec.stall_window,
  retry = spec.retry,
  ephemeral = spec.ephemeral,
  done = function(_event)
    return false
  end,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "github_issue_create",
}
