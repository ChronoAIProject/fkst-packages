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

local intake_marker

local function pr_list_json(prs)
  local rendered = {}
  for _, pr in ipairs(prs or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"state":"%s","updated_at":"%s"}',
      pr.number,
      json_string(pr.state or "OPEN"),
      json_string(pr.updated_at or "2026-06-04T01:02:03Z")
    ))
  end
  return "[[" .. table.concat(rendered, ",") .. "]]"
end

local function mock_pr_list(prs)
  t.mock_command("repos/owner/repo/pulls?state=open&per_page=100", {
    stdout = pr_list_json(prs) .. "\n",
    stderr = "",
    exit_code = 0,
  })
end

local function pr_origin_json(number, issue_number, state)
  local impl_version = "ready/consensus-github-devloop/issue/owner/repo/" .. tostring(issue_number) .. "/2026-06-03T01-02-03Z"
  local proposal_id = "github-devloop/issue/owner/repo/" .. tostring(issue_number)
  local comments = {
    core.pr_origin_marker(
      proposal_id,
      tostring(issue_number),
      "devloop-owner-repo-" .. tostring(issue_number),
      impl_version,
      "dev"
    ),
    core.state_marker(proposal_id, "pr-open", impl_version),
  }
  local rendered = {}
  for _, comment in ipairs(comments) do
    table.insert(rendered, render_comment(comment))
  end
  return string.format(
    '{"headRefName":"devloop-owner-repo-%d","headRefOid":"def%d","baseRefName":"dev","state":"%s","updatedAt":"2026-06-04T01:02:03Z","comments":[%s]}\n',
    issue_number,
    number,
    json_string(state or "OPEN"),
    table.concat(rendered, ",")
  )
end

local function mock_pr_origin(number, issue_number, state)
  t.mock_command("--json headRefName,headRefOid,baseRefName,state,updatedAt,comments", {
    stdout = pr_origin_json(number, issue_number, state),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_result(number, intake_class, author)
  t.mock_command("--json labels,comments", {
    stdout = issue_view_json({ "fkst-dev:enabled" }, { intake_marker(number, intake_class, author) }),
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

local function run_observe_pr_tick(run_opts)
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = "dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 3 do
    t.mock_command("rev-parse --abbrev-ref HEAD", {
      stdout = "dev\n",
      stderr = "",
      exit_code = 0,
    })
  end
  return t.run_department("departments/observe_pr/main.lua", {
    queue = "devloop_observe_tick",
    payload = { schema = "github-devloop.observe-tick.v1" },
  }, run_opts)
end

intake_marker = function(number, intake_class, author)
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

  test_observe_pr_tick_orders_open_prs_by_trusted_intake_class_and_preserves_fifo = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_pr_list({
      { number = 10, updated_at = "2026-06-04T01:00:00Z" },
      { number = 11, updated_at = "2026-06-04T01:01:00Z" },
      { number = 12, updated_at = "2026-06-04T01:02:00Z" },
    })
    mock_pr_origin(10, 40)
    mock_issue_result(40, "background")
    mock_pr_origin(11, 41)
    mock_issue_result(41, "standard")
    mock_pr_origin(12, 42)
    mock_issue_result(42, "expedite")
    mock_pr_origin(12, 42)
    mock_pr_origin(11, 41)
    mock_pr_origin(10, 40)

    local result = run_observe_pr_tick(opts("observe-pr-class-order"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 9)
    t.eq(result.raises[2].queue, "devloop_reviewing")
    t.eq(result.raises[2].payload.proposal_id, "github-devloop/issue/owner/repo/42")
    t.eq(result.raises[5].queue, "devloop_reviewing")
    t.eq(result.raises[5].payload.proposal_id, "github-devloop/issue/owner/repo/41")
    t.eq(result.raises[8].queue, "devloop_reviewing")
    t.eq(result.raises[8].payload.proposal_id, "github-devloop/issue/owner/repo/40")
  end,

  test_observe_pr_tick_keeps_non_expedite_capacity_under_expedite_pressure = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_pr_list({
      { number = 20, updated_at = "2026-06-04T01:00:00Z" },
      { number = 21, updated_at = "2026-06-04T01:01:00Z" },
      { number = 22, updated_at = "2026-06-04T01:02:00Z" },
      { number = 23, updated_at = "2026-06-04T01:03:00Z" },
      { number = 24, updated_at = "2026-06-04T01:04:00Z" },
    })
    mock_pr_origin(20, 50)
    mock_issue_result(50, "background")
    mock_pr_origin(21, 51)
    mock_issue_result(51, "standard")
    mock_pr_origin(22, 52)
    mock_issue_result(52, "expedite")
    mock_pr_origin(23, 53)
    mock_issue_result(53, "expedite")
    mock_pr_origin(24, 54)
    mock_issue_result(54, "expedite")
    mock_pr_origin(22, 52)
    mock_pr_origin(23, 53)
    mock_pr_origin(21, 51)

    local result = run_observe_pr_tick(opts("observe-pr-class-capacity"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 9)
    t.eq(result.raises[2].payload.proposal_id, "github-devloop/issue/owner/repo/52")
    t.eq(result.raises[5].payload.proposal_id, "github-devloop/issue/owner/repo/53")
    t.eq(result.raises[8].payload.proposal_id, "github-devloop/issue/owner/repo/51")
  end,
}
