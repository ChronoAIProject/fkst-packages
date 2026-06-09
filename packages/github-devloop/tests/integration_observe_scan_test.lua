local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts

local function json_string(value)
  return h.json_string(value)
end

local function render_comment(comment)
  return h.render_comment(comment)
end

local function labels_json(labels)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, string.format('{"name":"%s"}', json_string(label)))
  end
  return table.concat(rendered, ",")
end

local function comments_json(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  return table.concat(rendered, ",")
end

local function issue_list_json(issues)
  local rendered = {}
  for _, issue in ipairs(issues or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"title":"%s","updatedAt":"%s","labels":[%s]}',
      issue.number,
      json_string(issue.title or "Issue"),
      json_string(issue.updated_at or "2026-06-03T01:02:03Z"),
      labels_json(issue.labels or {})
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]"
end

local function pr_list_json(prs)
  local rendered = {}
  for _, pr in ipairs(prs or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"headRefName":"%s","headRefOid":"%s","baseRefName":"%s","state":"%s","updatedAt":"%s"}',
      pr.number,
      json_string(pr.head_ref_name or "devloop-owner-repo-42"),
      json_string(pr.head_sha or "66cb07110313d619caa512938f3a9d46169416ba"),
      json_string(pr.base_ref_name or "dev"),
      json_string(pr.state or "OPEN"),
      json_string(pr.updated_at or "2026-06-03T01:02:03Z")
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]"
end

local function mock_repo_env()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_list(issues)
  t.mock_command("--state all --limit 100 --json number,title,updatedAt,labels", {
    stdout = issue_list_json(issues) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_list(prs)
  t.mock_command("--state all --limit 100 --json number,headRefName,headRefOid,baseRefName,state,updatedAt", {
    stdout = pr_list_json(prs) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_observe_view(labels, comments, state)
  t.mock_command("--json labels,comments,state", {
    stdout = string.format(
      '{"state":"%s","labels":[%s],"comments":[%s]}\n',
      json_string(state or "OPEN"),
      labels_json(labels or {}),
      comments_json(comments or {})
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr_observe_view(pr)
  t.mock_command("--json headRefName,headRefOid,baseRefName,state,updatedAt,comments", {
    stdout = string.format(
      '{"headRefName":"%s","headRefOid":"%s","baseRefName":"%s","state":"%s","updatedAt":"%s","comments":[%s]}\n',
      json_string(pr.head_ref_name or "devloop-owner-repo-42"),
      json_string(pr.head_sha or "66cb07110313d619caa512938f3a9d46169416ba"),
      json_string(pr.base_ref_name or "dev"),
      json_string(pr.state or "OPEN"),
      json_string(pr.updated_at or "2026-06-03T01:02:03Z"),
      comments_json(pr.comments or {})
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_graph_scan()
  t.mock_command("find departments -mindepth 2 -maxdepth 2 -name main.lua -type f", {
    stdout = table.concat({
      "departments/observe_scan/main.lua",
      "departments/observe_report/main.lua",
    }, "\n") .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function find_graph(graph, dept)
  for _, edge in ipairs(graph or {}) do
    if edge.dept == dept then
      return edge
    end
  end
  return nil
end

local function run_scan()
  return t.run_department("departments/observe_scan/main.lua", {
    queue = "devloop_observe_tick",
    ts = "2026-06-09T01:02:03Z",
    payload = { schema = "github-devloop.observe-tick.v1" },
  }, opts("observe-scan"))
end

local function run_report(payload)
  return t.run_department("departments/observe_report/main.lua", {
    queue = "devloop_state_snapshot",
    payload = payload,
  }, opts("observe-report"))
end

return {
  test_observe_scan_raises_current_state_snapshot = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({
      { number = 42, labels = { "fkst-dev:reviewing" } },
      { number = 43, labels = {} },
    })
    mock_observe_view({ "fkst-dev:reviewing" }, {
      {
        body = core.state_marker("github-devloop/issue/owner/repo/42", "thinking", "consensus:2026-06-03T01:02:03Z"),
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T01:03:03Z",
      },
      {
        body = core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", "ready/consensus-2026-06-03T01:02:03Z"),
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T02:03:03Z",
      },
      {
        body = core.state_marker("github-devloop/issue/owner/repo/42", "merged", "ready/consensus-2026-06-03T01:02:03Z"),
        author_login = "ordinary-user",
        created_at = "2026-06-03T03:03:03Z",
      },
    }, "OPEN")
    mock_observe_view({}, {}, "OPEN")
    mock_pr_list({})
    mock_graph_scan()

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local raised = result.raises[1]
    t.eq(raised.queue, "devloop_state_snapshot")
    t.eq(raised.payload.schema, "github-devloop.state-snapshot.v1")
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.observed_at, "2026-06-09T01:02:03Z")
    t.eq(raised.payload.source_ref.ref, "owner/repo#state-snapshot")
    t.eq(#raised.payload.entities, 1)
    local entity = raised.payload.entities[1]
    t.eq(entity.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(entity.state, "reviewing")
    t.eq(entity.recent_transition.from, "thinking")
    t.eq(entity.recent_transition.to, "reviewing")
    t.is_nil(entity.recent_markers)
    local observe_scan = find_graph(raised.payload.graph, "observe_scan")
    t.eq(observe_scan.consumes[1], "devloop_observe_tick")
    t.eq(observe_scan.produces[1], "devloop_state_snapshot")
  end,

  test_observe_summary_includes_marker_managed_without_label = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = {} } })
    mock_observe_view({}, {
      {
        body = core.state_marker("github-devloop/issue/owner/repo/42", "blocked", "consensus:2026-06-03T01:02:03Z"),
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T01:03:03Z",
      },
    }, "OPEN")
    mock_pr_list({})
    mock_graph_scan()

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(#result.raises[1].payload.entities, 1)
    t.eq(result.raises[1].payload.entities[1].state, "blocked")
    t.eq(result.raises[1].payload.entities[1].label_hint, false)
  end,

  test_observe_scan_ignores_label_without_trusted_marker = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = { "fkst-dev:ready" } } })
    mock_observe_view({ "fkst-dev:ready" }, {}, "OPEN")
    mock_pr_list({})
    mock_graph_scan()

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(#result.raises[1].payload.entities, 0)
  end,

  test_observe_scan_includes_pr_comment_stream_state = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({})
    mock_pr_list({ { number = 97 } })
    mock_pr_observe_view({
      state = "OPEN",
      comments = {
        {
          body = core.pr_origin_marker(
            "github-devloop/issue/owner/repo/42",
            42,
            "devloop-owner-repo-42",
            "ready/consensus-2026-06-03T01:02:03Z",
            "dev"
          ),
          author_login = "fkst-test-bot",
          created_at = "2026-06-03T01:03:03Z",
        },
        {
          body = core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", "ready/consensus-2026-06-03T01:02:03Z"),
          author_login = "fkst-test-bot",
          created_at = "2026-06-03T02:03:03Z",
        },
        {
          body = core.state_marker("github-devloop/issue/owner/repo/42", "merge-ready", "ready/consensus-2026-06-03T01:02:03Z/review/approve"),
          author_login = "fkst-test-bot",
          created_at = "2026-06-03T03:03:03Z",
        },
      },
    })
    mock_graph_scan()

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(#result.raises[1].payload.entities, 1)
    local entity = result.raises[1].payload.entities[1]
    t.eq(entity.kind, "pr")
    t.eq(entity.number, "97")
    t.eq(entity.issue_number, "42")
    t.eq(entity.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(entity.state, "merge-ready")
    t.eq(entity.recent_transition.from, "reviewing")
    t.eq(entity.recent_transition.to, "merge-ready")
    t.eq(entity.source_ref.ref, "owner/repo#pr/97")
  end,

  test_observe_report_consumes_snapshot_without_side_effects = function()
    local payload = core.build_state_snapshot_payload("owner/repo", {
      {
        proposal_id = "github-devloop/issue/owner/repo/42",
        github_state = "OPEN",
        state = "ready",
        version = "ready/2026-06-03T01:02:03Z",
        recent_transition = { from = "thinking", to = "ready" },
      },
    }, {}, "2026-06-09T01:02:03Z")

    local result = run_report(payload)
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
