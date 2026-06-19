local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "devloop_substrate_ref_tick" },
  produces = {
    "github-proxy.github_pr_comment_request",
  },
  stall_window = "5m",
}

local function substrate_ref_scan_done(_event)
  return false
end

local function substrate_ref_scan_act(event)
  core.log_entry("substrate_ref_scan", event, "repo-management-plane", "tick")
  core.substrate_ref_scan()
end

return saga.department(spec, {
  done = substrate_ref_scan_done,
  act = substrate_ref_scan_act,
  name = "substrate_ref_scan",
})
