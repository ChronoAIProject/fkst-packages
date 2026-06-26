local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local find_raise = h.find_raise
local count_calls = h.count_calls
local entity_read_mocks = require("tests.entity_read_mock_helpers")

local function mock_repo_env(repo)
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = "dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = "dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = repo or "owner/repo",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_bot_env(value)
  h.mock_bot_env(value)
end

local function encode_json_string(value)
  return h.encode_json_string(value)
end

local function encode_labels_json(labels)
  local rendered = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered, string.format('{"name":"%s"}', encode_json_string(label)))
  end
  return table.concat(rendered, ",")
end

local function comments_json(comments)
  local rendered = {}
  for _, comment in ipairs(comments or {}) do
    table.insert(rendered, h.render_comment(comment))
  end
  return table.concat(rendered, ",")
end

local function trusted_reintake_command(id)
  return {
    id = id or "IC_reintake_1",
    body = "fkst: reintake",
    author_login = core.trusted_bot_login(),
    created_at = "2026-06-04T03:00:00Z",
  }
end

local function untrusted_reintake_command(id)
  local command = trusted_reintake_command(id or "IC_reintake_untrusted")
  command.author_login = "ordinary-user"
  return command
end

local function find_comment_body(raises, needle)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request"
      and raised.payload.body:find(needle, 1, true) ~= nil then
      return raised.payload
    end
  end
  return nil
end

local function expected_scan_effect_key(proposal_id, issue, command)
  return core.intake_decision_dedup_key(proposal_id, { title = issue and issue.title or "Issue", body = issue and issue.body or "" }, command)
end

local function issue_list_json(issues)
  local rendered = {}
  for _, issue in ipairs(issues or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"title":"%s","body":"%s","createdAt":"%s","updatedAt":"%s","labels":[%s],"assignees":[%s],"author":{"login":"%s"}}',
      issue.number,
      encode_json_string(issue.title or "Issue"),
      encode_json_string(issue.body or ""),
      encode_json_string(issue.created_at or "2026-06-03T01:00:00Z"),
      encode_json_string(issue.updated_at or "2026-06-03T01:02:03Z"),
      encode_labels_json(issue.labels or {}),
      issue.assignees_json or '{"login":"fkst-test-bot"}',
      encode_json_string(issue.author_login or "fkst-test-bot")
    ))
  end
  return "[" .. table.concat(rendered, ",") .. "]"
end

local function mock_issue_list(issues)
  entity_read_mocks.mock_issue_list_raw_command(t, core.gh_issue_list_intake_cmd("owner/repo", 100), {
    stdout = issue_list_json(issues) .. "\n",
  })
end

local function mock_intake_scan_view(labels, comments, state, number)
  entity_read_mocks.mock_issue_view_selector(t, {
    number = number,
    title = "Issue",
    state = state or "OPEN",
    labels = labels,
    comments = comments,
  }, "title,labels,comments,state,assignees,author")
end

local function run_scan(run_opts)
  return t.run_department("departments/intake_scan/main.lua", {
    queue = "devloop_intake_tick",
    payload = { schema = "github-devloop.intake-tick.v1" },
  }, run_opts)
end

return {
  test_scan_filters_enabled_closed_and_trusted_marker = function()
    mock_bot_env()
    mock_repo_env()
    mock_issue_list({
      { number = 40, labels = { "fkst-dev:enabled" } },
      { number = 41, labels = { "fkst-dev:thinking" } },
      { number = 42, labels = { "fkst-dev:hold" } },
      { number = 43, labels = { "fkst-class:expedite" } },
      { number = 44, labels = {} },
      { number = 45, labels = {} },
    })
    mock_intake_scan_view({ "fkst-dev:enabled" }, {}, "OPEN", 40)
    mock_intake_scan_view({ "fkst-dev:thinking" }, {}, "OPEN", 41)
    mock_intake_scan_view({ "fkst-dev:hold" }, {}, "OPEN", 42)
    mock_intake_scan_view({ "fkst-class:expedite" }, {}, "OPEN", 43)
    mock_intake_scan_view({}, {}, "CLOSED", 44)
    mock_intake_scan_view({}, {
      core.intake_decision_marker("github-devloop/issue/owner/repo/45", "decline", "intake/github-devloop/issue/owner/repo/45/v1", "standard"),
    }, "OPEN", 45)

    local result = run_scan(opts("intake-scan-filter"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "devloop_intake_candidate")
    t.eq(result.raises[1].payload.issue_number, "43")
    t.eq(result.raises[1].payload.source_ref.ref, "owner/repo#issue/43")
  end,

  test_scan_reintake_requeues_issue_with_trusted_intake_marker = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local command = trusted_reintake_command("IC_reintake_scan")
    mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = {} } })
    mock_intake_scan_view({}, {
      core.intake_decision_marker(proposal_id, "escalate-to-class", "intake/github-devloop/issue/owner/repo/42/v1", "standard"),
      command,
    }, "OPEN")

    local result = run_scan(opts("intake-scan-reintake"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "devloop_intake_candidate")
    t.eq(result.raises[1].payload.issue_number, "42")
    local expected_effect = expected_scan_effect_key(proposal_id, nil, command)
    t.eq(result.raises[1].payload.effect_id, expected_effect)
    t.eq(result.raises[1].payload.reintake_command_created_at, command.created_at)
    t.is_true(result.raises[1].payload.dedup_key ~= core.intake_dedup_key(proposal_id, "2026-06-03T01:02:03Z"))
    t.is_true(result.raises[1].payload.dedup_key:find("intake%-candidate/github%-devloop/issue/owner/repo/42", 1, false) ~= nil)
  end,

  test_scan_reintake_without_prior_intake_marker_refuses = function()
    mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = {} } })
    mock_intake_scan_view({}, {
      trusted_reintake_command("IC_reintake_no_marker"),
    }, "OPEN")

    local result = run_scan(opts("intake-scan-reintake-no-marker"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local refusal = find_comment_body(result.raises, "operator command refused")
    t.is_true(refusal ~= nil)
    t.is_true(refusal.body:find("reintake requires an existing intake decision", 1, true) ~= nil)
    t.is_true(refusal.body:find('outcome="refused"', 1, true) ~= nil)
  end,

  test_scan_reintake_mid_pipeline_refuses = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = { "fkst-dev:thinking" } } })
    mock_intake_scan_view({ "fkst-dev:thinking" }, {
      core.intake_decision_marker(proposal_id, "decline", "intake/github-devloop/issue/owner/repo/42/v1", "standard"),
      trusted_reintake_command("IC_reintake_active"),
    }, "OPEN")

    local result = run_scan(opts("intake-scan-reintake-active-state"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local refusal = find_comment_body(result.raises, "operator command refused")
    t.is_true(refusal ~= nil)
    t.is_true(refusal.body:find("reintake requires no active devloop state", 1, true) ~= nil)
    t.is_true(refusal.body:find('outcome="refused"', 1, true) ~= nil)
  end,

  test_scan_reintake_forged_command_is_ignored = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = {} } })
    mock_intake_scan_view({}, {
      core.intake_decision_marker(proposal_id, "decline", "intake/github-devloop/issue/owner/repo/42/v1", "standard"),
      untrusted_reintake_command("IC_reintake_forged"),
    }, "OPEN")

    local result = run_scan(opts("intake-scan-reintake-forged"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_scan_ignores_forged_marker = function()
    mock_bot_env()
    mock_repo_env()
    mock_issue_list({ { number = 42, labels = {} } })
    mock_intake_scan_view({}, {
      {
        body = core.intake_decision_marker("github-devloop/issue/owner/repo/42", "decline", "intake/github-devloop/issue/owner/repo/42/v1", "standard"),
        author_login = "ordinary-user",
      },
    }, "OPEN")

    local result = run_scan(opts("intake-scan-forged"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.issue_number, "42")
  end,
}
