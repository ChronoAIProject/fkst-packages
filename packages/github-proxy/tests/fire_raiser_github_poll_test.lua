local h = require("tests.proxy_integration_helpers")
local t = h.t

return {
  test_fire_raiser_github_poll_routes_and_raises_real_entities = function()
    h.mock_bot_env()
    h.mock_poll()

    local trace = t.fire_raiser("github_poll")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser:match("([^.]+)$"), "github_poll")
    t.eq(trace.routed_to[1]:match("([^.]+)$"), "github_poll")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 2)
    t.eq(trace.raised[1].queue:match("([^.]+)$"), "github_entity_changed")
    t.eq(trace.raised[1].payload.schema, "github-proxy.v1")
    t.eq(trace.raised[1].payload.type, "issue")
    t.eq(trace.raised[1].payload.repo, "owner/x")
    t.eq(trace.raised[1].payload.number, 42)
    t.eq(trace.raised[1].payload.updated_at, "2026-06-03T01:02:03Z")
    t.eq(trace.raised[1].payload.dedup_key, "owner/x#issue#42@2026-06-03T01:02:03Z")
    t.eq(trace.raised[1].payload.source_ref.ref, "owner/x#issue/42")
    t.eq(trace.raised[2].queue:match("([^.]+)$"), "github_entity_changed")
    t.eq(trace.raised[2].payload.schema, "github-proxy.v1")
    t.eq(trace.raised[2].payload.type, "pr")
    t.eq(trace.raised[2].payload.repo, "owner/x")
    t.eq(trace.raised[2].payload.number, 7)
    t.eq(trace.raised[2].payload.updated_at, "2026-06-03T02:03:04Z")
    t.eq(trace.raised[2].payload.dedup_key, "owner/x#pr#7@2026-06-03T02:03:04Z")
    t.eq(trace.raised[2].payload.source_ref.ref, "owner/x#pr/7")
  end,
}
