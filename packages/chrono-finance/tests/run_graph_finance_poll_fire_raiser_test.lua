-- Producer-liveness + cross-package coverage for chrono-finance's cron producer.
-- Fires the real `finance_poll` raiser in-process (mocking the sandboxed env read
-- and the codex usage summary), asserts the tick routes to the report department
-- and that it produces one bounded github-proxy report request. Modeled on
-- git-branch-detector/tests/run_graph_git_ref_poll_fire_raiser_test.lua.
local graph = require("testkit.graph")
local t = fkst.test

local function mock_env()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_FINANCE_BUDGET_MAX_UNITS"', { stdout = "", stderr = "", exit_code = 0 })
end

local function mock_codex_usage()
  t.mock_command("codex exec", {
    stdout = '{"summary":"Two merged PRs implementing the dashboard.","total_units":90,'
      .. '"line_items":[{"area":"PR #42","units":60},{"area":"PR #43","units":30}]}',
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_fire_raiser_finance_poll_routes_tick_to_report_and_files_one_issue = function()
    mock_env()
    mock_codex_usage()

    local trace = t.fire_raiser("finance_poll")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "chrono-finance.finance_poll")
    t.eq(trace.routed_to[1], "chrono-finance.report")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")

    t.eq(#trace.raised, 1)
    t.eq(trace.raised[1].queue, "github-proxy.github_issue_create_request")
    t.eq(trace.raised[1].payload.schema, "github-proxy.issue-create.v1")
    t.eq(trace.raised[1].payload.repo, "owner/repo")
    t.is_true(trace.raised[1].payload.title:find("Finance report", 1, true) ~= nil)

    graph.assert_covers(trace, {
      "chrono-finance.finance_tick -> chrono-finance.report",
    })
  end,
}
