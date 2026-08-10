local entity_lib = require("devloop.entity")
local entity_list_cache = require("devloop.entity_list_cache")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local gh_argv = require("testkit_internal.gh_argv_mock")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local admission_department = require("departments.admission.main")
local author_policy = require("testkit_internal.github_author_policy")
local github_author_policy = require("devloop.github_author_policy")
local github_factory = require("devloop.github_factory")
local m_claims = require("devloop.claims")
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

local function mock_admission_view(number, created_at, fields)
  local selected = fields or {}
  entity_read_mocks.mock_issue_view_selector(t, {
    number = number,
    title = "External issue " .. tostring(number),
    body = "",
    created_at = created_at or os.date("!%Y-%m-%dT%H:%M:%SZ", now()),
    updated_at = "2026-07-30T01:02:03Z",
    state = selected.state or "OPEN",
    labels = selected.labels or {},
    comments = selected.comments or {},
    assignees = selected.assignees or {},
    author_login = selected.author_login or "trusted-human",
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

local allocated_poll_epochs = {}

local function set_current_poll_epoch(poll_token, expect_stale)
  if poll_token ~= nil then
    local existing_epoch = allocated_poll_epochs[poll_token]
    if not expect_stale and existing_epoch ~= nil then
      return existing_epoch
    end
    local recorded, allocated_epoch = entity_list_cache.record_poll_epoch(repo, poll_token)
    if expect_stale then
      t.eq(recorded, false)
      return existing_epoch, allocated_epoch
    else
      t.is_true(recorded)
      t.is_true(entity_list_cache.poll_epoch_is_current(repo, allocated_epoch))
      allocated_poll_epochs[poll_token] = allocated_epoch
    end
    return allocated_epoch
  end
end

local active_run_opts = nil

local test_capacity = {
  authorize = function()
    return true, "peer scan test capacity"
  end,
  relinquish = function()
    return true, "peer scan test capacity"
  end,
  reconcile = function()
    return true, "peer scan test capacity"
  end,
}

local function run_admission(run_opts, number, poll_token, created_at, opts)
  local options = opts or {}
  if active_run_opts ~= run_opts then
    cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
    active_run_opts = run_opts
    allocated_poll_epochs = {}
  end
  if options.current_epoch ~= nil then
    set_current_poll_epoch(options.current_epoch)
  elseif options.preserve_current_epoch ~= true then
    local allocated_epoch = set_current_poll_epoch(poll_token, options.expect_stale_epoch == true)
    if allocated_epoch ~= nil then
      poll_token = allocated_epoch
    end
  end
  mock_event_env()
  mock_admission_view(number, created_at, options.current)
  local department = admission_department.make_department({
    capacity = options.capacity or test_capacity,
    claims = options.claims,
  })
  return testing.run_fake_outcome(department, entity_changed(number, poll_token))
end

local function assert_no_admission_effect(result)
  t.eq(result.exit_code, 0)
  t.eq(#result.raises, 0)
  t.eq(h.find_raise(result.raises, "github-proxy.github_issue_create_request"), nil)
  t.eq(h.find_raise(result.raises, "devloop_intake_candidate"), nil)
end

local function claims_advancing_epoch_after_precheck(next_epoch)
  return {
    claim_admission_inputs = m_claims.claim_admission_inputs,
    claim_admission_precheck = function(current, inputs)
      local admission, detail = m_claims.claim_admission_precheck(current, inputs)
      local recorded = entity_list_cache.record_poll_epoch(repo, next_epoch)
      t.is_true(recorded)
      return admission, detail
    end,
    claim_issue_for_management = m_claims.claim_issue_for_management,
    run_if_current_claim_admission_epoch = m_claims.run_if_current_claim_admission_epoch,
  }
end

local function counting_capacity(counter)
  return {
    authorize = function()
      counter.calls = counter.calls + 1
      return true, "peer scan test capacity"
    end,
    relinquish = test_capacity.relinquish,
    reconcile = test_capacity.reconcile,
  }
end

local function assert_peer_decision_is_rechecked(name, first_issue_rows, second_issue_rows, expected_capacity_calls)
  local run_opts = h.opts("peer-scan-stale-decision-" .. name)
  local counter = { calls = 0 }
  local capacity = counting_capacity(counter)
  local poll_a = "peer-scan-" .. name .. "-01"
  local advanced = "peer-scan-" .. name .. "-02"
  local poll_b = "peer-scan-" .. name .. "-03"

  mock_peer_result(issue_peer_command, { stdout = first_issue_rows, stderr = "", exit_code = 0 })
  mock_peer_result(pr_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 })
  assert_no_admission_effect(run_admission(run_opts, 81, poll_a, nil, {
    capacity = capacity,
    claims = claims_advancing_epoch_after_precheck(advanced),
  }))
  t.eq(counter.calls, 0, "stale " .. name .. " decision is not consumed at the effect boundary")

  mock_peer_result(issue_peer_command, { stdout = second_issue_rows, stderr = "", exit_code = 0 })
  mock_peer_result(pr_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 })
  assert_no_admission_effect(run_admission(run_opts, 81, poll_b, nil, {
    capacity = capacity,
  }))
  t.eq(counter.calls, expected_capacity_calls, "the next poll re-evaluates the " .. name .. " decision")
  t.eq(count_peer_calls(issue_peer_command), 2)
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

    assert_no_admission_effect(run_admission(run_opts, 46, nil))
    assert_no_admission_effect(run_admission(run_opts, 47, nil))
    t.eq(count_peer_calls(issue_peer_command), 2, "tokenless admission performs no issue peer scan")
    t.eq(count_peer_calls(pr_peer_command), 2, "tokenless admission performs no PR peer scan")
  end,

  test_positive_peer_bot_snapshot_is_rechecked_when_epoch_advances_after_precheck = function()
    local peer_rows = '[{"number":7,"comments":[{"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"x\\" state=\\"thinking\\" version=\\"v\\" -->","author":{"login":"trusted-human"}}],"author":{"login":"trusted-human"}}]\n'
    assert_peer_decision_is_rechecked("positive-peer-bot", peer_rows, "[]\n", 1)
  end,

  test_negative_peer_bot_snapshot_is_rechecked_when_epoch_advances_after_precheck = function()
    local peer_rows = '[{"number":7,"comments":[{"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"x\\" state=\\"thinking\\" version=\\"v\\" -->","author":{"login":"trusted-human"}}],"author":{"login":"trusted-human"}}]\n'
    assert_peer_decision_is_rechecked("negative-peer-bot", "[]\n", peer_rows, 0)
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

  test_issue_scan_failure_settles_once_for_all_same_batch_admissions = function()
    local run_opts = h.opts("peer-issue-scan-failure-settled")
    mock_peer_result(issue_peer_command, { stdout = "", stderr = "rate limited", exit_code = 1 }, 2)

    for number = 61, 62 do
      assert_no_admission_effect(run_admission(run_opts, number, "poll-batch-issue-failure"))
    end

    t.eq(count_peer_calls(issue_peer_command), 1, "issue scan cost does not grow with batch size")
    t.eq(count_peer_calls(pr_peer_command), 0, "PR discovery does not run after unavailable issue discovery")
  end,

  test_pr_scan_failure_settles_once_for_all_same_batch_admissions = function()
    local run_opts = h.opts("peer-pr-scan-failure-settled")
    mock_peer_result(issue_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 }, 2)
    mock_peer_result(pr_peer_command, { stdout = "", stderr = "rate limited", exit_code = 1 }, 2)

    for number = 63, 64 do
      assert_no_admission_effect(run_admission(run_opts, number, "poll-batch-pr-failure"))
    end

    t.eq(count_peer_calls(issue_peer_command), 1, "issue scan remains one per batch")
    t.eq(count_peer_calls(pr_peer_command), 1, "PR scan cost does not grow with batch size")
  end,

  test_thrown_peer_discovery_settles_once_per_source_without_admission_effects = function()
    local run_opts = h.opts("peer-thrown-scan-failure-settled")
    local issue_calls = 0
    local pr_calls = 0
    local policy = github_author_policy.from_logins({ "fkst-test-bot", "trusted-human" })
    local handle = {
      _trusted_author_policy = function()
        return policy
      end,
      issue_list_cli = function()
        issue_calls = issue_calls + 1
        return { stdout = "[]", stderr = "", exit_code = 0 }
      end,
      pr_list_cli = function()
        pr_calls = pr_calls + 1
        error("simulated PR discovery throw")
      end,
    }
    local original_production_handle = github_factory.production_handle
    github_factory.production_handle = function()
      return handle
    end
    local ok, err = pcall(function()
      for number = 65, 66 do
        assert_no_admission_effect(run_admission(run_opts, number, "poll-batch-thrown-failure"))
      end
    end)
    github_factory.production_handle = original_production_handle
    if not ok then
      error(err, 0)
    end

    t.eq(issue_calls, 1, "issue source settles once")
    t.eq(pr_calls, 1, "thrown PR source settles once")
  end,

  test_thrown_issue_discovery_settles_once_without_running_pr_source = function()
    local run_opts = h.opts("peer-thrown-issue-scan-failure-settled")
    local issue_calls = 0
    local pr_calls = 0
    local policy = github_author_policy.from_logins({ "fkst-test-bot", "trusted-human" })
    local handle = {
      _trusted_author_policy = function()
        return policy
      end,
      issue_list_cli = function()
        issue_calls = issue_calls + 1
        error("simulated issue discovery throw")
      end,
      pr_list_cli = function()
        pr_calls = pr_calls + 1
        return { stdout = "[]", stderr = "", exit_code = 0 }
      end,
    }
    local original_production_handle = github_factory.production_handle
    github_factory.production_handle = function()
      return handle
    end
    local ok, err = pcall(function()
      for number = 69, 70 do
        assert_no_admission_effect(run_admission(run_opts, number, "poll-batch-thrown-issue-failure"))
      end
    end)
    github_factory.production_handle = original_production_handle
    if not ok then
      error(err, 0)
    end

    t.eq(issue_calls, 1, "thrown issue source settles once")
    t.eq(pr_calls, 0, "PR discovery does not run after unavailable issue discovery")
  end,

  test_replayed_older_dynamic_peer_poll_epoch_stays_stale_without_admission_effect_or_scan = function()
    local run_opts = h.opts("peer-scan-stale-poll-epoch")
    local created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (3 * 60 * 60) - 1)
    local peer_marker_rows = '[{"number":7,"comments":[{"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"x\\" state=\\"thinking\\" version=\\"v\\" -->","author":{"login":"trusted-human"}}],"author":{"login":"trusted-human"}}]'
    local poll_a = "2026-07-30T01:02:03Z"
    local poll_b = "2026-07-30T01:02:04Z"

    mock_peer_result(issue_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 })
    mock_peer_result(pr_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 })
    mock_fork_state_view(71, created_at)
    run_admission(run_opts, 71, poll_a, created_at)

    mock_peer_result(issue_peer_command, { stdout = peer_marker_rows, stderr = "", exit_code = 0 })
    mock_peer_result(pr_peer_command, { stdout = "[]\n", stderr = "", exit_code = 0 })
    assert_no_admission_effect(run_admission(run_opts, 72, poll_b, created_at))

    local issue_scans = count_peer_calls(issue_peer_command)
    local pr_scans = count_peer_calls(pr_peer_command)
    mock_fork_state_view(71, created_at)
    local delayed = run_admission(run_opts, 71, poll_a, created_at, {
      expect_stale_epoch = true,
    })

    assert_no_admission_effect(delayed)
    t.is_true(entity_list_cache.poll_epoch_is_current(repo, allocated_poll_epochs[poll_b]), "newer poll epoch remains current")
    t.eq(count_peer_calls(issue_peer_command), issue_scans, "stale epoch performs no issue scan")
    t.eq(count_peer_calls(pr_peer_command), pr_scans, "stale epoch performs no PR scan")
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
