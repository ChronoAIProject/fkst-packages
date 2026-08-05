local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
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
  test_admission_skips_only_strictly_older_reconciled_entity_versions = function()
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
        return repo, issue_number, closed_issue(updated_at)
      end,
    })

    local captured_logs = {}
    local original_log_line = devloop_logging.log_line
    devloop_logging.log_line = function(level, dept, proposal_id, tag, fields)
      table.insert(captured_logs, table.concat(fields or {}, " "))
      return original_log_line(level, dept, proposal_id, tag, fields)
    end

    local v0 = "2026-08-04T00:00:00Z"
    local v1 = "2026-08-04T00:01:00Z"
    local v2 = "2026-08-04T00:02:00Z"
    local ok, err = pcall(function()
      testing.run_fake(department, event(v1))
      testing.run_fake(department, event(v0))
      testing.run_fake(department, event(v1))
      testing.run_fake(department, event(v2))
      testing.run_fake(department, event(v2))
    end)
    devloop_logging.log_line = original_log_line
    if not ok then
      error(err, 0)
    end

    t.eq(#reads, 4, "V0 must skip while equal and newer versions still fetch")
    t.eq(reads[1], v1)
    t.eq(reads[2], v1)
    t.eq(reads[3], v2)
    t.eq(reads[4], v2)
    t.eq(cache_get(highwater_key), v2)

    local skip_fact = nil
    for _, line in ipairs(captured_logs) do
      if line:find("outcome=skip-superseded-version", 1, true) ~= nil then
        skip_fact = line
        break
      end
    end
    t.is_true(skip_fact ~= nil)
    t.is_true(skip_fact:find("incoming_updated_at=" .. v0, 1, true) ~= nil)
    t.is_true(skip_fact:find("stored_updated_at=" .. v1, 1, true) ~= nil)
    t.is_true(skip_fact:find("entity=owner/repo#issue/3093", 1, true) ~= nil)
  end,

  test_admission_coalesces_equal_observations_and_refetches_newer_versions = function()
    h.mock_bot_env()
    cache_set(highwater_key, "")
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

    testing.run_fake(department, event(v1, "poll-1"))
    testing.run_fake(department, event(v1, "poll-1"))
    testing.run_fake(department, event(v2, "poll-2"))

    t.eq(count_intake_views(), 2, "equal versions share one view while a newer version re-fetches")
  end,
}
