local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "github_issue_blocked_by_request" },
  stall_window = "30s",
}

local function completion_rechecked_at_write_boundary(_event)
  -- write_issue_blocked_by_request checks trusted markers and the GitHub edge under the target lock.
  return false
end

local function act(event)
  core.write_issue_blocked_by_request(event.payload or {})
end

return saga.department{
  consumes = spec.consumes,
  produces = spec.produces,
  fanout = spec.fanout,
  stall_window = spec.stall_window,
  retry = spec.retry,
  ephemeral = spec.ephemeral,
  done = completion_rechecked_at_write_boundary,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "github_issue_blocked_by",
}
