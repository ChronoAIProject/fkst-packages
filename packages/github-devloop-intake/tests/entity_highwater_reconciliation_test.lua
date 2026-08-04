local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local admission_department = require("departments.admission.main")

local t = h.t
local repo = "owner/repo"
local issue_number = 3093
local source_ref = entity_lib.issue_source_ref(repo, issue_number)
local highwater_key = "github-devloop-intake/admission/highwater/owner/repo/issue/3093"

local function version(number)
  local offset = number - 1
  local minute = math.floor(offset / 60)
  local second = offset % 60
  return string.format("2026-08-04T00:%02d:%02dZ", minute, second)
end

local function event(updated_at)
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
}
