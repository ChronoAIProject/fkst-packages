-- Cross-package run_graph coverage for chrono-marketing's consumed edge: an OPEN
-- fkst-marketing content-request issue (github-proxy.github_entity_changed) reaches
-- the generate department, which drafts content (mocked codex) and produces a
-- github-proxy comment request. Modeled on
-- github-autochrono/tests/run_graph_entity_changed_inbound_glue_smoke_test.lua.
local graph = require("testkit.graph")
local t = fkst.test

local repo = "owner/repo"
local issue_number = 42

local function initial_event()
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      state = "OPEN",
      repo = repo,
      number = issue_number,
      title = "Announce the dashboard",
      url = "https://github.com/owner/repo/issues/42",
      body = "Draft a launch post for the new dashboard.",
      labels = { "fkst-company", "fkst-marketing" },
      updated_at = "2026-06-19T01:00:00Z",
      dedup_key = "owner/repo#issue#42@2026-06-19T01:00:00Z",
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    },
    source_ref = { kind = "external", reference = "owner/repo#issue/42" },
  }
end

local function mock_codex_draft()
  t.mock_command("codex exec", {
    stdout = '{"title":"Introducing the dashboard","channel":"social",'
      .. '"body_markdown":"The new dashboard ships today.","image_prompt":"a clean dashboard"}',
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_run_graph_marketing_request_reaches_generate_and_comments = function()
    mock_codex_draft()

    local trace = graph.require_quiescent(graph.run(initial_event(), { max_steps = 4 }))
    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> chrono-marketing.generate",
    })

    local step = graph.require_delivery(trace, {
      queue = "github-proxy.github_entity_changed",
      consumer = "chrono-marketing.generate",
    })
    t.eq(step.exit_code, 0)

    graph.require_raise(trace, "github-proxy.github_issue_comment_request", function(raised)
      local payload = raised.payload or {}
      return payload.schema == "github-proxy.v1"
        and payload.repo == repo
        and payload.issue_number == issue_number
        and payload.body:find("The new dashboard ships today.", 1, true) ~= nil
    end)
  end,
}
