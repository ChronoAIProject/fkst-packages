-- #2887: the implement local-iteration gate ran on a hardcoded 7200s timeout while the codex
-- attempt budget it verifies is role-env-configurable (`FKST_CODEX_TIMEOUT_IMPLEMENT`). On a
-- deployment that raises the attempt budget, the gate could time out while the attempt was still
-- inside its budget: the verification returned UNKNOWN and the attempt's real outcome was lost to
-- pure configuration skew between two layers of the same pipeline.
--
-- The gate must derive its budget from the same source of truth as the attempt, not restate it.
-- These assertions are made on the options actually handed to exec, not on a helper's return
-- value: a gate that recomputed the number at the call site would still pass a pure-function test.
local h = require("tests.devloop_helpers")
local t = h.t
local harvest = require("departments.implement.harvest")
local codex = require("workflow_internal.codex")

local function captures()
  local calls = {}
  return calls, function(opts)
    table.insert(calls, opts)
    return { stdout = "", stderr = "FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE\n", exit_code = 0 }
  end
end

local function mock_local_test_command()
  t.mock_command('printf %s "$FKST_DEVLOOP_LOCAL_TEST_COMMAND"', {
    stdout = "make preflight",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_attempt_budget(seconds)
  t.mock_command('printf %s "$FKST_CODEX_TIMEOUT_IMPLEMENT"', {
    stdout = tostring(seconds),
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_role_timeout_seconds_defaults_to_the_implement_attempt_budget = function()
    t.eq(codex.role_timeout_seconds("implement"), 5 * 60 * 60)
  end,

  test_role_timeout_seconds_follows_the_role_env_override = function()
    mock_attempt_budget(10800)

    t.eq(codex.role_timeout_seconds("implement"), 10800)
  end,

  test_role_timeout_seconds_rejects_an_unknown_role = function()
    local ok, err = pcall(codex.role_timeout_seconds, "not-a-role")

    t.eq(ok, false)
    t.is_true(tostring(err):find("timeout-role-unknown", 1, true) ~= nil)
  end,

  test_local_gate_runs_on_the_default_attempt_budget = function()
    local calls, exec = captures()
    mock_local_test_command()

    harvest.local_iteration_check("/tmp/fkst worktree", "abc123", { exec = exec })

    t.eq(#calls, 1)
    t.eq(calls[1].timeout, 2 * 60 * 60)
  end,

  -- The regression #2887 reports: raising the attempt budget must raise the gate with it.
  test_local_gate_follows_a_raised_attempt_budget = function()
    local calls, exec = captures()
    mock_attempt_budget(10800)
    mock_local_test_command()

    harvest.local_iteration_check("/tmp/fkst worktree", "abc123", { exec = exec })

    t.eq(#calls, 1)
    t.eq(calls[1].timeout, 10800)
  end,

  test_local_gate_still_runs_the_configured_command_in_the_worktree = function()
    local calls, exec = captures()
    mock_local_test_command()

    harvest.local_iteration_check("/tmp/fkst worktree", "abc123", { exec = exec })

    t.is_true(calls[1].cmd:find("export BASE='abc123' && make preflight", 1, true) ~= nil)
  end,
}
