local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local count_calls = h.count_calls

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

local function list_result(stdout)
  return {
    stdout = stdout .. "\n",
    stderr = "",
    exit_code = 0,
  }
end

local function collect_snapshot_with(issue_list, issue_views, pr_list, pr_views)
  local next_issue_view = 0
  local next_pr_view = 0
  return core.collect_state_snapshot("owner/repo", core.observe_scope(100, 100), function(cmd)
    if cmd:find("gh issue list", 1, true) then
      return list_result(issue_list_json(issue_list or {}))
    end
    if cmd:find("gh issue view", 1, true) then
      next_issue_view = next_issue_view + 1
      local view = issue_views[next_issue_view] or {}
      return list_result(string.format(
        '{"state":"%s","labels":[%s],"comments":[%s]}',
        json_string(view.state or "OPEN"),
        labels_json(view.labels or {}),
        comments_json(view.comments or {})
      ))
    end
    if cmd:find("gh pr list", 1, true) then
      return list_result(pr_list_json(pr_list or {}))
    end
    if cmd:find("gh pr view", 1, true) then
      next_pr_view = next_pr_view + 1
      local view = pr_views[next_pr_view] or {}
      return list_result(string.format(
        '{"headRefName":"%s","headRefOid":"%s","baseRefName":"%s","state":"%s","updatedAt":"%s","comments":[%s]}',
        json_string(view.head_ref_name or "devloop-owner-repo-42"),
        json_string(view.head_sha or "66cb07110313d619caa512938f3a9d46169416ba"),
        json_string(view.base_ref_name or "dev"),
        json_string(view.state or "OPEN"),
        json_string(view.updated_at or "2026-06-03T01:02:03Z"),
        comments_json(view.comments or {})
      ))
    end
    return { stdout = "", stderr = "unexpected command: " .. tostring(cmd), exit_code = 1 }
  end)
end

return {
  test_observe_scan_raises_current_state_snapshot = function()
    h.mock_bot_env()
    mock_repo_env()

    local result = run_scan()
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local raised = result.raises[1]
    t.eq(raised.queue, "devloop_state_snapshot")
    t.eq(raised.payload.schema, "github-devloop.state-snapshot-ref.v1")
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.observed_at, "2026-06-09T01:02:03Z")
    t.eq(raised.payload.source_ref.ref, "owner/repo#state-snapshot")
    t.eq(raised.payload.scope.kind, "latest")
    t.eq(raised.payload.scope.issue_limit, 100)
    t.eq(raised.payload.scope.pr_limit, 100)
    t.is_nil(raised.payload.entities)
    t.is_nil(raised.payload.graph)
    t.eq(count_calls("gh issue list"), 0)
    t.eq(count_calls("gh pr list"), 0)
    t.eq(count_calls("find departments"), 0)
  end,

  test_observe_summary_includes_marker_managed_without_label = function()
    h.mock_bot_env()
    local snapshot = {
      repo = "owner/repo",
      observed_at = "2026-06-09T01:02:03Z",
      scope = core.observe_scope(100, 100),
    }
    snapshot.entities = collect_snapshot_with({ { number = 42, labels = {} } }, {
      {
        labels = {},
        comments = {
          {
            body = core.state_marker("github-devloop/issue/owner/repo/42", "blocked", "consensus:2026-06-03T01:02:03Z"),
            author_login = "fkst-test-bot",
            created_at = "2026-06-03T01:03:03Z",
          },
        },
      },
    }, {}, {})
    local lines = core.state_snapshot_report_lines(snapshot)
    t.eq(#snapshot.entities, 1)
    t.eq(snapshot.entities[1].state, "blocked")
    t.eq(snapshot.entities[1].label_hint, false)
    t.is_true(lines[5]:find("entities=1", 1, true) ~= nil)
  end,

  test_observe_report_rederives_current_state_from_source_ref = function()
    h.mock_bot_env()
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

    local result = run_report(core.build_state_snapshot_payload("owner/repo", "2026-06-09T01:02:03Z", core.observe_scope(100, 100)))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh issue list"), 1)
    t.eq(count_calls("gh issue view"), 2)
    t.eq(count_calls("gh pr list"), 1)
    t.eq(count_calls("find departments"), 0)
  end,

  test_observe_scan_ignores_label_without_trusted_marker = function()
    h.mock_bot_env()
    local entities = collect_snapshot_with({ { number = 42, labels = { "fkst-dev:ready" } } }, {
      { labels = { "fkst-dev:ready" }, comments = {} },
    }, {}, {})
    t.eq(#entities, 0)
  end,

  test_observe_scan_includes_pr_comment_stream_state = function()
    h.mock_bot_env()
    local entities = collect_snapshot_with({}, {}, { { number = 97 } }, {
      {
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
      },
    })
    t.eq(#entities, 1)
    local entity = entities[1]
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
    h.mock_bot_env()
    mock_issue_list({})
    mock_pr_list({})

    local payload = core.build_state_snapshot_payload("owner/repo", "2026-06-09T01:02:03Z", core.observe_scope(100, 100))

    local result = run_report(payload)
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh issue list"), 1)
    t.eq(count_calls("gh pr list"), 1)
  end,
}
