local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
require("departments.observability.main")

local function mock_env()
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
  end
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
  end
  for _, name in ipairs({ "GH_TOKEN", "GITHUB_TOKEN" }) do
    t.mock_command('if [ -n "${' .. name .. ':-}" ]; then printf present; fi', { stdout = "", stderr = "", exit_code = 0 })
  end
end

local function issue_list_first(label)
  return core.gh_issue_list_observe_cmd("owner/repo", label, 1, true)
end

local function run_pipeline()
  local old_pipeline = pipeline
  local module = require("departments.observability.main")
  local run = module.pipeline or pipeline
  pipeline = old_pipeline
  if type(run) ~= "function" then error("github-devloop: observability department pipeline missing") end
  run({ queue = "devloop_observe_tick", payload = { schema = "github-devloop.observe-tick.v1" } })
end

local function capture_logs()
  local captured = {}
  local old_log = log
  log = {
    info = function(message) table.insert(captured, tostring(message)) end,
    warn = function(message) table.insert(captured, tostring(message)) end,
    error = function(message) table.insert(captured, tostring(message)) end,
  }
  local ok, err = pcall(run_pipeline)
  log = old_log
  if not ok then error(err) end
  return table.concat(captured, "\n")
end

return {
  test_display_read_timeout_renders_partial_observability_dashboard = function()
    mock_env()
    t.mock_command(issue_list_first(core._enabled_label), { stdout = "", stderr = "timed out", exit_code = 124 })
    for _, state in ipairs(core.issue_state_order()) do
      t.mock_command(issue_list_first(core.state_label(state)), { stdout = "[]\n", stderr = "", exit_code = 0 })
    end
    t.mock_command(core.gh_pr_list_observe_cmd("owner/repo", 1, true), { stdout = "[]\n", stderr = "", exit_code = 0 })
    t.mock_command(core.gh_pr_list_recent_merged_cmd("owner/repo", core.observability_limits().entity_cap), { stdout = "[]\n", stderr = "", exit_code = 0 })
    t.mock_command(core.gh_issue_list_recent_closed_cmd("owner/repo", core.observability_limits().entity_cap), { stdout = "[]\n", stderr = "", exit_code = 0 })

    local logs = capture_logs()

    t.is_true(logs:find("tag=OBSERVE_READ_DEFERRED reason=timeout", 1, true) ~= nil)
    t.is_true(logs:find("tag=OBSERVE_DEFERRED reason=timeout", 1, true) ~= nil)
    t.is_true(logs:find("## Partial observations", 1, true) ~= nil)
    t.is_true(logs:find("- reason=timeout", 1, true) ~= nil)
  end,
}
