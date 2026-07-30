local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local gh_argv = require("testkit_internal.gh_argv_mock")
local h = require("tests.devloop_helpers")
local author_policy = require("testkit_internal.github_author_policy")
local t = h.t
local core = h.core

local repo = "owner/repo"
local issue_peer_command = "gh issue list --repo 'owner/repo' --state all --limit 100 --json number,comments,author"
local pr_peer_command = "gh pr list --repo 'owner/repo' --state all --limit 100 --json number,headRefName,baseRefName,comments,author"
local intake_fields = "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone"

local function source_ref(number)
  return entity_lib.issue_source_ref(repo, number)
end

local function entity_changed(number, poll_token)
  local updated_at = "2026-07-30T01:02:" .. string.format("%02d", number % 60) .. "Z"
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = number,
      title = "External issue " .. tostring(number),
      state = "OPEN",
      labels = {},
      updated_at = updated_at,
      dedup_key = repo .. "#issue#" .. tostring(number) .. "@" .. updated_at,
      poll_token = poll_token,
      source_ref = source_ref(number),
    },
    source_ref = source_ref(number),
  }
end

local function mock_event_env()
  h.mock_bot_env()
  author_policy.mock_env(t, nil, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
    times = 4,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = "dev",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = "integration-fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_FORK_GRACE_HOURS"', { stdout = "", stderr = "", exit_code = 0 })
end

local function mock_admission_view(number, created_at)
  entity_read_mocks.mock_issue_view_selector(t, {
    number = number,
    title = "External issue " .. tostring(number),
    body = "",
    created_at = created_at or os.date("!%Y-%m-%dT%H:%M:%SZ", now()),
    updated_at = "2026-07-30T01:02:03Z",
    state = "OPEN",
    labels = {},
    comments = {},
    assignees = {},
    author_login = "trusted-human",
  }, intake_fields)
end

local function mock_fork_state_view(number, created_at)
  t.mock_command(core.gh_issue_view_state_cmd(repo, tostring(number)), {
    stdout = '{"title":"External issue","createdAt":"' .. tostring(created_at)
      .. '","updatedAt":"2026-07-30T01:02:03Z","state":"OPEN","labels":[],"comments":[],"assignees":[],"author":{"login":"trusted-human"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_peer_result(command, result, times)
  for _ = 1, times or 1 do
    t.mock_command(command, result)
  end
end

local function count_peer_calls(command)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if gh_argv.call_contains(call, command) then
      count = count + 1
    end
  end
  return count
end

local function run_admission(run_opts, number, poll_token, created_at)
  mock_event_env()
  mock_admission_view(number, created_at)
  return h.run_department("departments/admission/main.lua", entity_changed(number, poll_token), run_opts)
end

local function assert_no_admission_effect(result)
  t.eq(result.exit_code, 0)
  t.eq(#result.raises, 0)
  t.eq(h.find_raise(result.raises, "github-proxy.github_issue_create_request"), nil)
  t.eq(h.find_raise(result.raises, "devloop_intake_candidate"), nil)
end

return {
  test_peer_activity_scan_budget_is_constant_within_a_poll_batch = function()
    local run_opts = h.opts("peer-scan-poll-batch-budget")
    mock_peer_result(issue_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 }, 7)
    mock_peer_result(pr_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 }, 7)

    for number = 41, 43 do
      local result = run_admission(run_opts, number, "poll-batch-a")
      t.eq(result.exit_code, 0)
    end

    t.eq(count_peer_calls(issue_peer_command), 1, "one issue peer scan for the first batch")
    t.eq(count_peer_calls(pr_peer_command), 1, "one PR peer scan for the first batch")

    local issue_scans = count_peer_calls(issue_peer_command)
    local pr_scans = count_peer_calls(pr_peer_command)
    run_admission(run_opts, 44, "poll-batch-a")
    t.eq(count_peer_calls(issue_peer_command), issue_scans, "another same-batch issue adds no issue peer scan")
    t.eq(count_peer_calls(pr_peer_command), pr_scans, "another same-batch issue adds no PR peer scan")

    run_admission(run_opts, 45, "poll-batch-b")
    t.eq(count_peer_calls(issue_peer_command), 2, "a new batch re-derives the issue peer scan")
    t.eq(count_peer_calls(pr_peer_command), 2, "a new batch re-derives the PR peer scan")

    run_admission(run_opts, 46, nil)
    run_admission(run_opts, 47, nil)
    t.eq(count_peer_calls(issue_peer_command), 4, "missing batch keys perform fresh issue peer scans")
    t.eq(count_peer_calls(pr_peer_command), 4, "missing batch keys perform fresh PR peer scans")
  end,

  test_unavailable_peer_activity_scan_fails_closed_before_fork = function()
    local number = 51
    local created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (3 * 60 * 60) - 1)
    local run_opts = h.opts("peer-scan-unavailable-fails-closed")
    mock_peer_result(issue_peer_command, { stdout = "", stderr = "rate limited", exit_code = 1 })
    mock_peer_result(pr_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 })
    mock_fork_state_view(number, created_at)

    assert_no_admission_effect(run_admission(run_opts, number, "poll-batch-unavailable", created_at))
  end,

  test_malformed_peer_activity_scan_fails_closed_before_fork = function()
    local number = 52
    local created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (3 * 60 * 60) - 1)
    local run_opts = h.opts("peer-scan-malformed-fails-closed")
    mock_peer_result(issue_peer_command, { stdout = "not-json", stderr = "", exit_code = 0 })
    mock_peer_result(pr_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 })
    mock_fork_state_view(number, created_at)

    assert_no_admission_effect(run_admission(run_opts, number, "poll-batch-malformed", created_at))
  end,
}
