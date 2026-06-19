local core, saga = require("core"), require("std.saga")


local spec = {
  consumes = { "devloop_substrate_ref_tick" },
  produces = {

    "github-proxy.github_pr_comment_request",
  },
  stall_window = "5m",
}

return saga.department(spec, { done = function() return false end, act = function(event)
  core.log_entry("substrate_ref_scan", event, "repo-management-plane", "tick")
  core.substrate_ref_scan()
end,
  name = "substrate_ref_scan" })
