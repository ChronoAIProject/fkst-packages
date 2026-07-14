-- Producer-liveness + cross-package coverage for chrono-security's cron producer.
-- Fires the real `security_poll` raiser in-process (mocking the sandboxed env read
-- and the codex scan), asserts the trace routes to the scan department, and that
-- the scan produces a bounded github-proxy create request. Modeled on
-- git-branch-detector/tests/run_graph_git_ref_poll_fire_raiser_test.lua.
local graph = require("testkit.graph")
local t = fkst.test

local function mock_env()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_codex_one_finding()
  t.mock_command("codex exec", {
    stdout = '[{"file":"src/app.lua","line":12,"severity":"high",'
      .. '"title":"unbounded input reaches shell","remediation":"validate and quote the argument"}]',
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_fire_raiser_security_poll_routes_tick_to_scan_and_files_finding = function()
    mock_env()
    mock_codex_one_finding()

    local trace = t.fire_raiser("security_poll")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "chrono-security.security_poll")
    t.eq(trace.routed_to[1], "chrono-security.scan")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")

    t.eq(#trace.raised, 1)
    t.eq(trace.raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(trace.raised[1].payload.schema, "github-proxy.issue-create.v1")
    t.eq(trace.raised[1].payload.repo, "owner/repo")
    t.is_true(trace.raised[1].payload.title:find("src/app.lua:12", 1, true) ~= nil)

    graph.assert_covers(trace, {
      "chrono-security.security_tick -> chrono-security.scan",
    })
  end,
}
