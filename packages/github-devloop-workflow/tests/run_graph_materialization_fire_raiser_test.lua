local t = fkst.test
local core = require("core")
local actions = require("core.materialize.actions")
local graph = require("testkit.graph")
local gh_argv = require("testkit_internal.gh_argv_mock")
local fixtures = require("tests.run_graph_materialization_helpers")
gh_argv.install(t, core)

local repo = fixtures.repo
local origin_issue = fixtures.origin_issue
local origin = fixtures.origin
local workflow_history = fixtures.workflow_history
local ownership_json = fixtures.ownership_json
local rest_comments_json = fixtures.rest_comments_json
local stale_label_impl_failed_child_history = fixtures.stale_label_impl_failed_child_history
local mock_materialization_cycle = fixtures.mock_materialization_cycle
local mock_env = fixtures.mock_env
local mock_write_mode = fixtures.mock_write_mode

local function mock_empty_origin_list()
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_fire_raiser_materialization_poll_routes_real_tick_to_materializer = function()
    mock_env()
    mock_empty_origin_list()
    local trace = t.fire_raiser("materialization_poll")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "github-devloop-workflow.materialization_poll")
    t.eq(trace.routed_to[1], "github-devloop-workflow.workflow_materialize_next")
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 0)
    graph.assert_covers(trace, {})
  end,

  test_run_graph_replays_error_terminal_into_advisory_blocked_label = function()
    local terminal_body, terminal_err = core.marker.build_terminal_marker(
      origin,
      "error",
      "blueprint-digest-mismatch"
    )
    t.is_nil(terminal_err)
    mock_env()
    mock_write_mode("", 4)
    mock_materialization_cycle(workflow_history(false, terminal_body), nil, nil, false)

    local projection_trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/error-terminal-replay" },
    }, { max_steps = 4 }))

    local projection = graph.require_raise(projection_trace, "github-proxy.github_issue_comment_request")
    local projection_fact = core.marker.parse_label_projection_marker(projection.payload.body, origin)
    t.eq(projection_fact.state, "blocked")
    t.eq(projection_fact.generation, 1)

    local history = workflow_history(false, terminal_body)
    history[#history + 1] = { body = projection.payload.body, created_at = "2026-07-10T20:44:00Z" }
    mock_env()
    mock_write_mode("", 4)
    mock_materialization_cycle(history, nil, nil, false)
    local trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/error-terminal-projection" },
    }, { max_steps = 4 }))

    graph.assert_covers(trace, {
      "github-devloop-workflow.workflow_materialization_tick -> github-devloop-workflow.workflow_materialize_next",
      "github-proxy.github_issue_label_request -> github-proxy.github_issue_label",
    })
    local label = graph.require_raise(trace, "github-proxy.github_issue_label_request")
    t.eq(label.payload.add_labels[1], "fkst-dev:blocked")
    t.eq(label.payload.marker_guard.expected.state, "blocked")
    t.eq(label.payload.marker_guard.expected.generation, "1")
    t.eq(graph.find_raise(trace, "github-proxy.github_issue_comment_request"), nil)
  end,

  test_run_graph_rejects_delayed_active_projection_after_newer_blocked_generation = function()
    local active_marker, active_err = core.marker.build_label_projection_marker(origin, "thinking", 2)
    local blocked_marker, blocked_err = core.marker.build_label_projection_marker(origin, "blocked", 3)
    t.is_nil(active_err)
    t.is_nil(blocked_err)
    local stale_request = actions.label_projection_request(repo, origin_issue, origin, {
      origin = origin,
      state = "thinking",
      generation = 2,
    }, { "fkst-dev:enabled", "fkst-dev:blocked" })

    mock_env()
    mock_write_mode("1", 2)
    t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(origin_issue), {
      stdout = ownership_json(), stderr = "", exit_code = 0,
    })
    local comments = rest_comments_json({ { body = active_marker }, { body = blocked_marker } })
    for _, command in ipairs({
      "gh api --paginate --slurp repos/" .. repo .. "/issues/" .. tostring(origin_issue) .. "/comments?per_page=100",
      "gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. tostring(origin_issue) .. "/comments?per_page=100'",
    }) do
      t.mock_command(command, { stdout = comments, stderr = "", exit_code = 0 })
    end

    local trace = graph.require_quiescent(graph.run({
      queue = "github-proxy.github_issue_label_request",
      payload = stale_request,
      source_ref = { kind = "external", reference = repo .. "#issue/" .. tostring(origin_issue) },
    }, { max_steps = 2 }))
    local label_step = graph.require_delivery(trace, {
      queue = "github-proxy.github_issue_label_request",
      consumer = "github-proxy.github_issue_label",
    })
    t.eq(label_step.exit_code, 0)
    local edit_calls = 0
    for _, call in ipairs(t.command_calls()) do
      if gh_argv.call_contains(call, "gh issue edit") then
        edit_calls = edit_calls + 1
      end
    end
    t.eq(edit_calls, 0)
  end,

  test_run_graph_terminalizes_parent_from_impl_failure_while_child_label_is_stale = function()
    local child_stdout = stale_label_impl_failed_child_history()
    mock_env()
    mock_write_mode("", 5)
    mock_materialization_cycle(workflow_history(true), "OPEN", nil, false, child_stdout)

    local terminal_trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/stale-child-label-terminal" },
    }, { max_steps = 4 }))
    local terminal = graph.require_raise(terminal_trace, "github-proxy.github_issue_comment_request")
    t.is_true(terminal.payload.body:find('state="blocked"', 1, true) ~= nil)
    t.is_true(terminal.payload.body:find('reason_code="child-fatal-behavior-preserving-restructure-no-changes"', 1, true) ~= nil)

    local terminal_history = workflow_history(true, terminal.payload.body)
    mock_env()
    mock_write_mode("", 5)
    mock_materialization_cycle(terminal_history, "OPEN", nil, false, child_stdout)
    local projection_trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/stale-child-label-projection" },
    }, { max_steps = 4 }))
    local projection = graph.require_raise(projection_trace, "github-proxy.github_issue_comment_request")
    local projection_fact = core.marker.parse_label_projection_marker(projection.payload.body, origin)
    t.eq(projection_fact.state, "blocked")
    t.eq(projection_fact.generation, 1)

    terminal_history[#terminal_history + 1] = {
      body = projection.payload.body,
      created_at = "2026-07-10T20:44:00Z",
    }
    mock_env()
    mock_write_mode("", 7)
    mock_materialization_cycle(terminal_history, "OPEN", nil, false, child_stdout)
    local label_trace = graph.require_quiescent(graph.run({
      queue = "github-devloop-workflow.workflow_materialization_tick",
      payload = { schema = "github-devloop-workflow.materialization-tick.v1" },
      source_ref = { kind = "cron", reference = "github-devloop-workflow.materialization_poll/stale-child-label-repair" },
    }, { max_steps = 4 }))
    graph.assert_covers(label_trace, {
      "github-devloop-workflow.workflow_materialization_tick -> github-devloop-workflow.workflow_materialize_next",
      "github-proxy.github_issue_label_request -> github-proxy.github_issue_label",
    })
    local label = graph.require_raise(label_trace, "github-proxy.github_issue_label_request")
    t.eq(label.payload.add_labels[1], "fkst-dev:blocked")
    t.eq(label.payload.marker_guard.expected.state, "blocked")
    t.eq(label.payload.marker_guard.expected.generation, "1")
  end,
}
