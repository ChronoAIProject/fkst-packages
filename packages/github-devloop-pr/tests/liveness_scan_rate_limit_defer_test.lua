local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")
local support = require("devloop.commands.support")
local testing = require("testkit_internal.testing")

local t = h.t
local core = h.core
local department = require("departments.liveness_scan.main")

local function has_field(fields, expected)
  for _, field in ipairs(fields or {}) do
    if field == expected then
      return true
    end
  end
  return false
end

local function with_repo(repo, fn)
  local original_read_env = devloop_base.read_env
  devloop_base.read_env = function(name)
    if name == "FKST_GITHUB_REPO" then
      return repo
    end
    return original_read_env(name)
  end
  local ok, result = pcall(fn)
  devloop_base.read_env = original_read_env
  if not ok then
    error(result, 0)
  end
  return result
end

local function capture_log_lines(fn)
  local captured = {}
  local original_log_line = devloop_logging.log_line
  devloop_logging.log_line = function(level, dept, proposal_id, tag, fields)
    table.insert(captured, {
      level = level,
      dept = dept,
      proposal_id = proposal_id,
      tag = tag,
      fields = fields,
    })
  end
  local ok, result = pcall(fn)
  devloop_logging.log_line = original_log_line
  if not ok then
    error(result, 0)
  end
  return result, captured
end

local function run_pr_list_failure(repo, stderr, ts)
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = "",
    stderr = stderr,
    exit_code = 1,
  })
  local outcome, logs
  with_repo(repo, function()
    outcome, logs = capture_log_lines(function()
      return testing.run_fake_outcome(department, {
        queue = "github-devloop-pr.devloop_liveness_tick",
        payload = { schema = "github-devloop.tick.v1" },
        ts = ts,
      })
    end)
  end)
  return outcome, logs
end

return {
  test_gh_result_preserves_adapter_classification_on_command_result = function()
    local command_result = {
      stdout = "",
      stderr = "gh: API rate limit exceeded (HTTP 403)",
      exit_code = 1,
    }
    local projected = support.gh_result(function()
      error({
        class = "gh-rate-limited",
        retryable = true,
        permanent = false,
        result = command_result,
      })
    end)

    t.is_true(projected == command_result)
    t.eq(projected.class, "gh-rate-limited")
    t.eq(projected.error_class, "gh-rate-limited")
    t.eq(projected.retryable, true)
    t.eq(projected.permanent, false)
  end,

  test_liveness_scan_rate_limit_defers_but_unknown_list_failure_still_raises = function()
    local unknown = run_pr_list_failure(
      "owner/unknown-list-failure",
      "GraphQL: upstream service failed",
      "2026-07-31T01:00:00Z"
    )
    t.eq(unknown.exit_code, 1)
    t.is_true(tostring(unknown.error):find("liveness-scan-pr-list-failed", 1, true) ~= nil)

    local deferred, logs = run_pr_list_failure(
      "owner/rate-limited-list",
      "gh: API rate limit exceeded for user (HTTP 403)",
      "2026-07-31T01:05:00Z"
    )
    t.eq(deferred.exit_code, 0)
    t.eq(#deferred.raises, 0)
    t.eq(#deferred.writes, 0)

    local deferred_fact
    for _, entry in ipairs(logs) do
      if entry.tag == "LIVENESS_DEFERRED" then
        deferred_fact = entry
      end
    end
    t.is_true(deferred_fact ~= nil)
    t.eq(deferred_fact.level, "info")
    t.eq(deferred_fact.dept, "liveness_scan")
    t.is_true(has_field(deferred_fact.fields, "reason=gh-rate-limited"))
    t.is_true(has_field(deferred_fact.fields, "error_class=gh-rate-limited"))
  end,
}
