local graph = require("testkit.graph")
local t = fkst.test

local repo = "owner/repo"

local function rest_issue(number, body)
  return '{"number":' .. tostring(number)
    .. ',"title":"fixture","body":' .. require("contract.strings").json_string(body or "")
    .. ',"state":"open","html_url":"https://github.example/' .. repo .. '/issues/' .. tostring(number)
    .. '","updated_at":"2026-07-29T00:00:00Z","labels":[],"user":{"login":"author"},"assignees":[]}'
end

local function mock_issue(number, body)
  t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(number), {
    stdout = rest_issue(number, body),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. tostring(number) .. "/comments?per_page=100'", {
    stdout = "[]",
    stderr = "",
    exit_code = 0,
  })
end

local function event()
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = 20,
      state = "OPEN",
      updated_at = "2026-07-29T00:00:00Z",
      dedup_key = repo .. "#issue/20@2026-07-29T00:00:00Z",
      source_ref = {
        kind = "external",
        ref = repo .. "#issue/20",
      },
    },
    source_ref = {
      kind = "external",
      reference = repo .. "#issue/20",
    },
  }
end

return {
  test_run_graph_delivers_github_entity_changed_to_marketing_radar_ingest = function()
    mock_issue(20, table.concat({
      "config-ref: owner/repo#issue/10",
      "signal-ref: owner/repo#issue/11",
    }, "\n"))
    mock_issue(10, "config body should not copy")
    mock_issue(11, "signal body should not copy")

    local trace = graph.run(event(), { max_steps = 3 })
    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> marketing-radar.ingest",
    })
    local create = graph.require_raise(trace, "github-proxy.github_issue_create_request")
    local receipt = graph.require_raise(trace, "marketing-radar.radar_weekly_content_generated")

    t.eq(create.payload.schema, "github-proxy.issue-create.v1")
    t.eq(create.payload.source_ref.ref, "owner/repo#issue/20")
    t.eq(receipt.payload.schema, "marketing-radar.weekly-content-generated.v1")
    t.eq(receipt.payload.issue_create_dedup_key, create.payload.dedup_key)
  end,
}
