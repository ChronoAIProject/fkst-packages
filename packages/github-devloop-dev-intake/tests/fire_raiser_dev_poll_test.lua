-- Producer-liveness: the dev_poll cron raiser must route to the dev_select department.
-- With no discoverable fkst-dev issues (the GitHub port degrades to empty), the tick is
-- accepted and produces no candidate -- the honest "nothing to admit" trace. This asserts
-- the four trace fields the producer-liveness ratchet requires: consumer_result /
-- source_payload / raised / routed_to.
local helper = require("tests.fire_raiser_helpers")
local t = fkst.test

return {
  test_fire_raiser_dev_poll_routes_to_dev_select = function()
    local root = helper.setup_workspace("route", helper.fire_raiser_child([[
  test_dev_poll_routes = function()
    mock_env()

    local trace = t.fire_raiser("dev_poll")
    t.eq(trace.source_payload.raiser, "github-devloop-dev-intake.dev_poll")
    t.eq(trace.routed_to[1], "github-devloop-dev-intake.dev_select")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 0)
  end,
]]))
    local output = helper.run_child(root)
    t.is_true(output:find("1 passed, 0 failed", 1, true) ~= nil, output)
  end,
}
