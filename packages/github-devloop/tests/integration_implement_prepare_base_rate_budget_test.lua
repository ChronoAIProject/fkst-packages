local h = require("tests.devloop_helpers")
local t = h.t

local function mock_missing_integration_branch()
  for _ = 1, 2 do
    t.mock_command("git fetch 'origin' 'dev'", {
      stdout = "",
      stderr = "fatal: couldn't find remote ref dev",
      exit_code = 128,
    })
  end
end

local function mock_branch_config()
  for _ = 1, 2 do
    t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function run_implement(event, name)
  return h.run_department("departments/implement/main.lua", {
    queue = "devloop_ready",
    payload = event,
  }, h.opts(name))
end

return {
  test_prepare_base_failure_retries_do_not_consume_github_entity_budget = function()
    local event = h.ready()
    mock_branch_config()
    mock_missing_integration_branch()

    local first = run_implement(event, "implement-prepare-base-failure-1")
    local second = run_implement(event, "implement-prepare-base-failure-2")

    t.eq(first.exit_code, 1)
    t.eq(second.exit_code, 1)
    t.is_true(tostring(first.error or first.stderr or ""):find("integration-branch-fetch-failed", 1, true) ~= nil)
    t.is_true(tostring(second.error or second.stderr or ""):find("integration-branch-fetch-failed", 1, true) ~= nil)
  end,
}
