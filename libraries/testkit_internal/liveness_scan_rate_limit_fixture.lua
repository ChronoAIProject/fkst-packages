local testing = require("testkit_internal.testing")

local M = {}

local function has_field(fields, expected)
  for _, field in ipairs(fields or {}) do
    if field == expected then
      return true
    end
  end
  return false
end

local function with_repo(devloop_base, repo, fn)
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

local function capture_log_lines(devloop_logging, fn)
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

local function run_list_failure(deps, repo, stderr, ts)
  deps.t.mock_command(deps.list_command(repo), {
    stdout = "",
    stderr = stderr,
    exit_code = 1,
  })
  local outcome, logs
  with_repo(deps.devloop_base, repo, function()
    outcome, logs = capture_log_lines(deps.devloop_logging, function()
      return testing.run_fake_outcome(deps.department, {
        queue = deps.queue,
        payload = { schema = "github-devloop.tick.v1" },
        ts = ts,
      })
    end)
  end)
  return outcome, logs
end

function M.assert_behavior(deps)
  local unknown = run_list_failure(
    deps,
    "owner/unknown-list-failure",
    "GraphQL: upstream service failed",
    "2026-07-31T01:00:00Z"
  )
  deps.t.eq(unknown.exit_code, 1)
  deps.t.is_true(tostring(unknown.error):find(deps.unknown_error, 1, true) ~= nil)

  local deferred, logs = run_list_failure(
    deps,
    "owner/rate-limited-list",
    "gh: API rate limit exceeded for user (HTTP 403)",
    "2026-07-31T01:05:00Z"
  )
  deps.t.eq(deferred.exit_code, 0)
  deps.t.eq(#deferred.raises, 0)

  local deferred_fact
  for _, entry in ipairs(logs) do
    if entry.tag == "LIVENESS_DEFERRED" then
      deferred_fact = entry
    end
  end
  deps.t.is_true(deferred_fact ~= nil)
  deps.t.eq(deferred_fact.level, "info")
  deps.t.eq(deferred_fact.dept, "liveness_scan")
  deps.t.is_true(has_field(deferred_fact.fields, "reason=gh-rate-limited"))
  deps.t.is_true(has_field(deferred_fact.fields, "error_class=gh-rate-limited"))
end

return M
