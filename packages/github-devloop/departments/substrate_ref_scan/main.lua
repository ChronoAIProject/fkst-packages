local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "devloop_substrate_ref_tick" },
  produces = {
    "github-proxy.github_pr_comment_request",
  },
  stall_window = "5m",
}

local function act(event)
  core.log_entry("substrate_ref_scan", event, "repo-management-plane", "tick")
  core.substrate_ref_scan()
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
  name = "substrate_ref_scan",
}
