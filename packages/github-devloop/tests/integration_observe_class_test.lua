local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local json_string = h.json_string
local render_comment = h.render_comment

local function labels_json(labels)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, string.format('{"name":"%s"}', json_string(label)))
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
      labels_json(issue.labels or { "fkst-dev:enabled" })
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]"
end

local function comments_json(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, render_comment(comment))
  end
  return table.concat(rendered, ",")
end

local function mock_repo_env()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_list(issues)
  t.mock_command("--state open --limit 100 --json number,title,updatedAt,labels", {
    stdout = issue_list_json(issues) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function issue_view_json(labels, comments, state)
  return string.format(
    '{"state":"%s","labels":[%s],"comments":[%s]}\n',
    json_string(state or "OPEN"),
    labels_json(labels or { "fkst-dev:enabled" }),
    comments_json(comments or {})
  )
end

local function mock_issue_view(labels, comments, state)
  t.mock_command("--json labels,state,comments", {
    stdout = issue_view_json(labels, comments, state),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_empty_dependencies()
  t.mock_command("gh api graphql", {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_observe_processing(labels, comments)
  mock_empty_dependencies()
  h.mock_context_bundle()
  mock_issue_view(labels, comments)
end

local function run_observe_tick(run_opts)
  return t.run_department("departments/observe_issue/main.lua", {
    queue = "devloop_observe_tick",
    payload = { schema = "github-devloop.observe-tick.v1" },
  }, run_opts)
end

local function intake_marker(number, intake_class, author)
  local proposal_id = "github-devloop/issue/owner/repo/" .. tostring(number)
  return {
    body = core.intake_decision_marker(proposal_id, "enable", "intake/" .. proposal_id .. "/v1", intake_class),
    author_login = author or core.trusted_bot_login(),
  }
end

return {
  test_observe_tick_orders_enabled_issues_by_trusted_intake_class_and_preserves_fifo = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({
      { number = 40, title = "Background", updated_at = "2026-06-03T01:00:00Z" },
      { number = 41, title = "Standard", updated_at = "2026-06-03T01:01:00Z" },
      { number = 42, title = "Expedite", updated_at = "2026-06-03T01:02:00Z" },
    })
    mock_issue_view({ "fkst-dev:enabled" }, { intake_marker(40, "background") })
    mock_issue_view({ "fkst-dev:enabled" }, { intake_marker(41, "standard") })
    mock_issue_view({ "fkst-dev:enabled" }, { intake_marker(42, "expedite") })
    mock_observe_processing({ "fkst-dev:enabled" }, { intake_marker(42, "expedite") })
    mock_observe_processing({ "fkst-dev:enabled" }, { intake_marker(41, "standard") })
    mock_observe_processing({ "fkst-dev:enabled" }, { intake_marker(40, "background") })

    local result = run_observe_tick(opts("observe-class-order"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 9)
    t.eq(result.raises[1].queue, "consensus.proposal")
    t.eq(result.raises[1].payload.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(result.raises[4].queue, "consensus.proposal")
    t.eq(result.raises[4].payload.proposal_id, "github-devloop/issue/owner/repo/41")
    t.eq(result.raises[7].queue, "consensus.proposal")
    t.eq(result.raises[7].payload.proposal_id, "github-devloop/issue/owner/repo/40")
  end,

  test_observe_tick_ignores_class_labels_and_forged_intake_markers = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({
      { number = 40, title = "Background", updated_at = "2026-06-03T01:00:00Z", labels = { "fkst-dev:enabled", "fkst-class:background" } },
      { number = 41, title = "Forged", updated_at = "2026-06-03T01:01:00Z", labels = { "fkst-dev:enabled", "fkst-class:expedite" } },
      { number = 42, title = "Standard", updated_at = "2026-06-03T01:02:00Z", labels = { "fkst-dev:enabled", "fkst-class:standard" } },
    })
    mock_issue_view({ "fkst-dev:enabled", "fkst-class:background" }, { intake_marker(40, "background") })
    mock_issue_view({ "fkst-dev:enabled", "fkst-class:expedite" }, { intake_marker(41, "expedite", "ordinary-user") })
    mock_issue_view({ "fkst-dev:enabled", "fkst-class:standard" }, { intake_marker(42, "standard") })
    mock_observe_processing({ "fkst-dev:enabled", "fkst-class:standard" }, { intake_marker(42, "standard") })
    mock_observe_processing({ "fkst-dev:enabled", "fkst-class:background" }, { intake_marker(40, "background") })

    local result = run_observe_tick(opts("observe-class-trust"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 6)
    t.eq(result.raises[1].payload.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(result.raises[4].payload.proposal_id, "github-devloop/issue/owner/repo/40")
  end,

  test_observe_tick_keeps_non_expedite_capacity_under_expedite_pressure = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue_list({
      { number = 50, title = "Background", updated_at = "2026-06-03T01:00:00Z" },
      { number = 51, title = "Standard", updated_at = "2026-06-03T01:01:00Z" },
      { number = 52, title = "Expedite one", updated_at = "2026-06-03T01:02:00Z" },
      { number = 53, title = "Expedite two", updated_at = "2026-06-03T01:03:00Z" },
      { number = 54, title = "Expedite three", updated_at = "2026-06-03T01:04:00Z" },
    })
    mock_issue_view({ "fkst-dev:enabled" }, { intake_marker(50, "background") })
    mock_issue_view({ "fkst-dev:enabled" }, { intake_marker(51, "standard") })
    mock_issue_view({ "fkst-dev:enabled" }, { intake_marker(52, "expedite") })
    mock_issue_view({ "fkst-dev:enabled" }, { intake_marker(53, "expedite") })
    mock_issue_view({ "fkst-dev:enabled" }, { intake_marker(54, "expedite") })
    mock_observe_processing({ "fkst-dev:enabled" }, { intake_marker(52, "expedite") })
    mock_observe_processing({ "fkst-dev:enabled" }, { intake_marker(53, "expedite") })
    mock_observe_processing({ "fkst-dev:enabled" }, { intake_marker(51, "standard") })

    local result = run_observe_tick(opts("observe-class-capacity"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 9)
    t.eq(result.raises[1].payload.proposal_id, "github-devloop/issue/owner/repo/52")
    t.eq(result.raises[4].payload.proposal_id, "github-devloop/issue/owner/repo/53")
    t.eq(result.raises[7].payload.proposal_id, "github-devloop/issue/owner/repo/51")
  end,
}
