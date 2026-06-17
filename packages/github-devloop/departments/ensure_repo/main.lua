local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "devloop_ensure_repo_tick" },
  produces = {},
  ephemeral = { "devloop_ensure_repo_tick" },
  retry = false,
  stall_window = "2m",
}

local function act(event)
  core.log_entry("ensure_repo", event, "repo-management-plane", "tick")
  core.ensure_repo()
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
  name = "ensure_repo",
}
