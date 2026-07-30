local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")
local rate_limit_fixture = require("testkit_internal.liveness_scan_rate_limit_fixture")

local core = h.core
local department = require("departments.liveness_scan.main")

return {
  test_liveness_scan_rate_limit_defers_but_unknown_list_failure_still_raises = function()
    rate_limit_fixture.assert_behavior({
      t = h.t,
      department = department,
      devloop_base = devloop_base,
      devloop_logging = devloop_logging,
      queue = "github-devloop.devloop_liveness_tick",
      list_command = core.gh_issue_list_observe_cmd,
      unknown_error = "liveness-scan-issue-list-failed",
    })
  end,
}
