local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "devloop_observe_tick" },
  produces = { "github-proxy.github_issue_create_request", "devloop_merge_queue_tick" },
  retry = false,
  stall_window = "2m",
}

local function act(event)
  core.log_entry("observability", event, "github-devloop/observability", "tick")
  core.observe_devloop_entities(event)
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
  name = "observability",
}
