local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local dashboard = require("devloop.dashboard")
local gh_argv = require("testkit_internal.gh_argv_mock")

local function mock_repo_env(repo)
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = repo or "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
end

local function source_ref(number)
  return entity_lib.issue_source_ref("owner/repo", number or 42)
end

local function entity_changed(number, fields)
  local f = fields or {}
  local selected = number or f.number or 42
  local updated_at = f.updated_at or "2026-06-03T01:02:03Z"
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = f.type or "issue",
      repo = f.repo or "owner/repo",
      number = selected,
      title = f.title or "Issue",
      state = f.state or "OPEN",
      labels = f.labels or {},
      updated_at = updated_at,
      dedup_key = tostring(f.repo or "owner/repo") .. "#issue#" .. tostring(selected) .. "@" .. tostring(updated_at),
      source_ref = source_ref(selected),
    },
    source_ref = source_ref(selected),
  }
end

local function mock_issue(number, fields)
  local f = fields or {}
  entity_read_mocks.mock_issue_view_selector(t, {
    number = number or 42,
    title = f.title or "Issue",
    body = f.body or "",
    updated_at = f.updated_at or "2026-06-03T01:02:03Z",
    state = f.state or "OPEN",
    labels = f.labels or {},
    comments = f.comments or {},
    assignees = f.assignees or { "fkst-test-bot" },
    author_login = f.author_login or "fkst-test-bot",
  }, "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone")
end

local function run_admission(event, run_opts)
  return t.run_department("departments/admission/main.lua", event or entity_changed(42), run_opts)
end

local function count_calls(needle)
  return gh_argv.count_calls(t, needle)
end

return {
  test_admission_skips_dashboard_anchor_before_claim_or_label_writes = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue(46, {
      body = "generated board\n" .. dashboard.marker("anchor", "2026-08-08T00:00:00Z"),
      assignees = {},
    })
    local result = run_admission(entity_changed(46), opts("intake-admission-dashboard-anchor", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("--add-assignee"), 0)
    t.eq(count_calls("--add-label"), 0)
  end,

  test_admission_filters_non_issue_closed_known_hold_and_trusted_marker = function()
    local cases = {
      { name = "pr", event = entity_changed(42, { type = "pr" }), view = nil },
      {
        name = "closed-event",
        event = entity_changed(42, { state = "CLOSED" }),
        view = { number = 42, state = "CLOSED" },
      },
      { name = "enabled", event = entity_changed(40), view = { number = 40, labels = { "fkst-dev:enabled" } } },
      { name = "thinking", event = entity_changed(41), view = { number = 41, labels = { "fkst-dev:thinking" } } },
      { name = "hold", event = entity_changed(42), view = { number = 42, labels = { "fkst-dev:hold" } } },
      {
        name = "trusted-marker",
        event = entity_changed(45),
        view = {
          number = 45,
          comments = {
            m_builders.intake_decision_marker("github-devloop/issue/owner/repo/45", "decline", "intake/github-devloop/issue/owner/repo/45/v1", "standard"),
          },
        },
      },
    }
    for _, case in ipairs(cases) do
      h.mock_bot_env()
      mock_repo_env()
      if case.view ~= nil then
        mock_issue(case.view.number, case.view)
      end
      local result = run_admission(case.event, opts("intake-admission-filter-" .. case.name))
      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 0)
    end
  end,

  test_admission_raises_candidate_for_open_unmanaged_issue = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue(43, { labels = { "fkst-class:expedite" } })

    local result = run_admission(entity_changed(43), opts("intake-admission-open"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "devloop_intake_candidate")
    t.eq(result.raises[1].payload.issue_number, "43")
    t.eq(result.raises[1].payload.source_ref.ref, "owner/repo#issue/43")
  end,

  test_admission_ignores_forged_marker = function()
    h.mock_bot_env()
    mock_repo_env()
    mock_issue(42, {
      comments = {
        {
          body = m_builders.intake_decision_marker("github-devloop/issue/owner/repo/42", "decline", "intake/github-devloop/issue/owner/repo/42/v1", "standard"),
          author_login = "ordinary-user",
        },
      },
    })

    local result = run_admission(entity_changed(42), opts("intake-admission-forged-marker"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.issue_number, "42")
  end,
}
