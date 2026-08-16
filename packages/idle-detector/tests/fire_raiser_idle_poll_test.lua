local t = fkst.test

return {
  -- Producer-liveness: proves `idle_poll` is not a dark raiser -- that a real cron tick
  -- reaches `idle_gate` through the production router, rather than only being exercised by
  -- the department-level tests that construct the department directly.
  --
  -- `raised` is empty and that is the assertion, not an omission: with no self-assigned open
  -- issue the gate accepts the tick and produces nothing. Pinning 0 here is what would break
  -- if the gate ever started emitting on an idle-less tick.
  test_fire_raiser_idle_poll_routes_real_tick_to_idle_gate = function()
    local trace = t.fire_raiser("idle_poll")

    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser:match("([^.]+)$"), "idle_poll")
    t.eq(trace.routed_to[1]:match("([^.]+)$"), "idle_gate")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 0)
  end,
}
