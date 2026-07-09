local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
local common = require("departments.observability.common")
local entity_read_mocks = require("tests.entity_read_mock_helpers")

local function with_exec_argv(fn)
  local old_exec_argv = exec_argv
  local old_exec_sync = exec_sync
  local calls = {}
  local env = {
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot",
    FKST_GITHUB_AUTHORIZED_LOGINS = "",
  }
  exec_argv = function(spec)
    table.insert(calls, spec)
    return {
      stdout = entity_read_mocks.issue_view_stdout({
        body = "issue body fix-feedback-marker-missing",
        comments = {
          { body = "comment fix-feedback-marker-missing", author_login = "fkst-test-bot" },
        },
      }),
      stderr = "",
      exit_code = 0,
    }
  end
  exec_sync = function(cmd)
    local name = tostring(cmd or ""):match('%$([A-Z0-9_]+)"?$')
    return { stdout = env[name] or "", stderr = "", exit_code = 0 }
  end
  local ok, result = pcall(fn, calls)
  exec_argv = old_exec_argv
  exec_sync = old_exec_sync
  if not ok then
    error(result)
  end
  return calls, result
end

return {
  test_observability_issue_fetch_uses_summary_only_audit_and_preserves_content = function()
    local calls, issue = with_exec_argv(function()
      return common.fetch_issue(core, "owner/repo", 42, core.observability_limits(), now() + 90)
    end)

    t.eq(#calls, 1)
    t.eq(calls[1].audit_output, "summary-only")
    t.eq(issue.body, "issue body fix-feedback-marker-missing")
    t.eq(issue.comments[1].body, "comment fix-feedback-marker-missing")
  end,
}
