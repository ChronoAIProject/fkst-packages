local graph = require("testkit.graph")
local t = fkst.test

local repo = "owner/repo"
local pr_number = 1493
local issue_number = 1494

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#pr/" .. tostring(pr_number),
  }
end

local function initial_event()
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = pr_number,
      title = "Autochrono bridge",
      url = "https://github.example/owner/repo/pull/" .. tostring(pr_number),
      state = "OPEN",
      updated_at = "2026-06-03T01:02:03Z",
      dedup_key = "owner/repo#pr/1493@2026-06-03T01:02:03Z",
      source_ref = source_ref(),
    },
    source_ref = {
      kind = "external",
      reference = "owner/repo#pr/" .. tostring(pr_number),
    },
  }
end

local function issue_event()
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Autochrono coverage",
      url = "https://github.example/owner/repo/issues/" .. tostring(issue_number),
      state = "CLOSED",
      updated_at = "2026-06-03T01:02:04Z",
      dedup_key = "owner/repo#issue/1494@2026-06-03T01:02:04Z",
      source_ref = {
        kind = "external",
        ref = "owner/repo#issue/" .. tostring(issue_number),
      },
    },
    source_ref = {
      kind = "external",
      reference = "owner/repo#issue/" .. tostring(issue_number),
    },
  }
end

return {
  test_run_graph_entity_changed_delivers_to_inbound_glue = function()
    local trace = graph.require_quiescent(graph.run(initial_event(), { max_steps = 2 }))
    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> github-autochrono.inbound_glue",
    })

    local inbound_step, inbound_index = graph.require_delivery(trace, {
      queue = "github-proxy.github_entity_changed",
      consumer = "github-autochrono.inbound_glue",
    })
    t.eq(inbound_step.exit_code, 0)
    t.eq(#(inbound_step.raises or {}), 0)
    t.eq(inbound_index, 1)
  end,

  test_run_graph_inbound_issue_handoff_reaches_autochrono_propose = function()
    local trace = graph.require_quiescent(graph.run(issue_event(), { max_steps = 3 }))
    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> github-autochrono.inbound_glue",
      "autochrono.issue -> autochrono.propose",
    })

    local inbound_step, inbound_index = graph.require_delivery(trace, {
      queue = "github-proxy.github_entity_changed",
      consumer = "github-autochrono.inbound_glue",
    })
    t.eq(#(inbound_step.raises or {}), 1)
    local issue_raise = inbound_step.raises[1]
    t.eq(issue_raise.payload.schema, "autochrono.issue.v1")
    t.eq(issue_raise.payload.repo, repo)
    t.eq(issue_raise.payload.issue_number, issue_number)
    t.eq(issue_raise.payload.state, "CLOSED")
    t.eq(issue_raise.payload.source_ref.ref, "owner/repo#issue/" .. tostring(issue_number))
    t.eq(issue_raise.payload.dedup_key, "owner/repo#issue/1494@2026-06-03T01:02:04Z")

    local propose_step, propose_index = graph.require_delivery(trace, {
      queue = "autochrono.issue",
      consumer = "autochrono.propose",
    })
    t.eq(propose_step.exit_code, 0)
    t.is_true(propose_index > inbound_index)
    t.eq(#(propose_step.raises or {}), 0)
  end,
}
