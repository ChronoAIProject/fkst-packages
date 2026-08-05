local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
local entity_list_cache = require("devloop.entity_list_cache")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local gh_argv = require("testkit_internal.gh_argv_mock")
local github_proxy_entity_view = require("devloop.github_proxy_entity_view")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local admission_department = require("departments.admission.main")

local t = h.t
local repo = "owner/repo"
local issue_number = 3093
local source_ref = entity_lib.issue_source_ref(repo, issue_number)
local highwater_key = "github-devloop-intake/admission/highwater/owner/repo/issue/3093"
local intake_fields = "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone"

local function version(number)
  local offset = number - 1
  local minute = math.floor(offset / 60)
  local second = offset % 60
  return string.format("2026-08-04T00:%02d:%02dZ", minute, second)
end

local function event(updated_at, poll_token)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "High-water reconciliation",
      state = "CLOSED",
      updated_at = updated_at,
      poll_token = poll_token,
      dedup_key = repo .. "#issue#" .. tostring(issue_number) .. "@" .. updated_at,
      source_ref = source_ref,
    },
    source_ref = source_ref,
  }
end

local function closed_issue(updated_at)
  return {
    number = issue_number,
    title = "High-water reconciliation",
    body = "",
    state = "CLOSED",
    updated_at = updated_at,
    labels = {},
    comments = {},
    assignees = {},
  }
end

local function count_intake_views()
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if gh_argv.call_contains(call, "gh issue view")
      and gh_argv.call_contains(call, intake_fields) then
      count = count + 1
    end
  end
  return count
end

return {
  test_oldest_admission_event_checkpoints_fetched_latest_version = function()
    h.mock_bot_env()
    cache_set(highwater_key, "")

    local reads = {}
    local department = admission_department.make_department({
      capacity = {
        reconcile = function()
          return true, "test-capacity-reconciled"
        end,
      },
      read_current_issue = function(_source_ref, updated_at)
        table.insert(reads, updated_at)
        return repo, issue_number, closed_issue(version(432))
      end,
    })

    local captured_logs = {}
    local original_log_line = devloop_logging.log_line
    devloop_logging.log_line = function(level, dept, proposal_id, tag, fields)
      table.insert(captured_logs, table.concat(fields or {}, " "))
      return original_log_line(level, dept, proposal_id, tag, fields)
    end

    local ok, err = pcall(function()
      testing.run_fake(department, event(version(1)))
      for number = 2, 431 do
        testing.run_fake(department, event(version(number)))
      end
    end)
    devloop_logging.log_line = original_log_line
    if not ok then
      error(err, 0)
    end

    t.eq(#reads, 1, "V1 fetching current V432 must make V2 through V431 zero-fetch no-ops")
    t.eq(reads[1], version(1))
    t.eq(cache_get(highwater_key), version(432))

    local skip_fact = nil
    for _, line in ipairs(captured_logs) do
      if line:find("outcome=skip-superseded-version", 1, true) ~= nil then
        skip_fact = line
        break
      end
    end
    t.is_true(skip_fact ~= nil)
    t.is_true(skip_fact:find("incoming_updated_at=" .. version(2), 1, true) ~= nil)
    t.is_true(skip_fact:find("stored_updated_at=" .. version(432), 1, true) ~= nil)
    t.is_true(skip_fact:find("entity=owner/repo#issue/3093", 1, true) ~= nil)
  end,

  test_admission_reuses_equal_current_observations_and_refetches_superseded_delivery = function()
    h.mock_bot_env()
    cache_set(highwater_key, "")
    cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
    github_proxy_entity_view.invalidate_entity_after_write(repo, "issue", issue_number)

    local v1 = "2026-08-04T00:01:00Z"
    local v2 = "2026-08-04T00:02:00Z"
    entity_read_mocks.mock_issue_view_selector(t, {
      repo = repo,
      number = issue_number,
      title = "Admission V1",
      state = "CLOSED",
      updated_at = v1,
    }, intake_fields, 1)
    entity_read_mocks.mock_issue_view_selector(t, {
      repo = repo,
      number = issue_number,
      title = "Admission stale delivery refresh",
      state = "CLOSED",
      updated_at = v1,
    }, intake_fields, 1)
    entity_read_mocks.mock_issue_view_selector(t, {
      repo = repo,
      number = issue_number,
      title = "Admission V2",
      state = "CLOSED",
      updated_at = v2,
    }, intake_fields, 1)

    local department = admission_department.make_department({
      capacity = {
        reconcile = function()
          return true, "test-capacity-reconciled"
        end,
      },
    })

    local recorded_poll_1, poll_1 = entity_list_cache.record_poll_epoch(repo, "2026-08-04T00:10:00Z")
    t.is_true(recorded_poll_1)
    testing.run_fake(department, event(v1, poll_1))
    testing.run_fake(department, event(v1, poll_1))

    local recorded_poll_2, poll_2 = entity_list_cache.record_poll_epoch(repo, "2026-08-04T00:11:00Z")
    t.is_true(recorded_poll_2)
    testing.run_fake(department, event(v1, poll_2))
    t.eq(count_intake_views(), 1, "a current later poll reuses the equal authoritative version")

    testing.run_fake(department, event(v1, poll_1))
    t.eq(count_intake_views(), 2, "a superseded poll delivery re-fetches instead of reusing cached stdout")

    local recorded_poll_3, poll_3 = entity_list_cache.record_poll_epoch(repo, "2026-08-04T00:12:00Z")
    t.is_true(recorded_poll_3)
    testing.run_fake(department, event(v2, poll_3))
    t.eq(count_intake_views(), 3, "a newer authoritative version re-fetches")
  end,

  test_admission_does_not_checkpoint_a_fetched_version_when_reconciliation_fails = function()
    h.mock_bot_env()
    cache_set(highwater_key, "")
    local reads = 0

    local function make_department(capacity)
      return admission_department.make_department({
        capacity = capacity,
        read_current_issue = function()
          reads = reads + 1
          return repo, issue_number, closed_issue(version(432))
        end,
      })
    end

    local failed = pcall(function()
      testing.run_fake(make_department({
        reconcile = function()
          error("test: capacity reconciliation failed")
        end,
      }), event(version(1)))
    end)
    t.eq(failed, false)
    t.eq(cache_get(highwater_key), "")

    testing.run_fake(make_department({
      reconcile = function()
        return true, "test-capacity-reconciled"
      end,
    }), event(version(2)))

    t.eq(reads, 2, "V2 must refetch after V1 fetched V432 but failed reconciliation")
    t.eq(cache_get(highwater_key), version(432))
  end,
}
