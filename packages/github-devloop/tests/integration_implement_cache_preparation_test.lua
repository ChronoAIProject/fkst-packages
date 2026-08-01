local h = require("tests.devloop_helpers")
local t = h.t
local ready = h.ready
local opts = h.opts
local run_implement = h.run_implement
local mock_issue_implement = h.mock_issue_implement
local deterministic_branch_for = h.deterministic_branch_for
local mock_fresh_implement_worktree = h.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree_reuse = h.mock_existing_empty_implement_worktree_reuse
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local mock_branch_diff_paths = h.mock_branch_diff_paths
local count_calls = h.count_calls

local cache_command = "make prepare-cache"
local cache_command_env = 'printf %s "$FKST_DEVLOOP_CACHE_PREPARATION_COMMAND"'
local current_base_pin = "2222222222222222222222222222222222222222"
local stale_branch_pin = "1111111111111111111111111111111111111111"

local function mock_cache_command(result)
  t.mock_command(cache_command_env, {
    stdout = cache_command,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(cache_command, result or {
    stdout = "cache ready\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_cache_command_unset()
  t.mock_command(cache_command_env, {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function command_index(needle)
  for index, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(needle, 1, true) ~= nil then
      return index
    end
  end
  return nil
end

local function command_call(needle)
  for _, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(needle, 1, true) ~= nil then
      return call
    end
  end
  return nil
end

local function command_env(call, name)
  for _, pair in ipairs((call and call.env) or {}) do
    if pair.key == name then
      return pair.value
    end
  end
  return nil
end

local function mock_successful_candidate(event)
  local branch = deterministic_branch_for(event)
  mock_implement_codex(0, "implemented after cache preparation")
  mock_git_status(" M packages/github-devloop/core.lua\n")
  mock_git_commit("def456", branch)
end

return {
  test_cache_preparation_runs_after_substrate_refresh_and_before_codex = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready", "fkst-dev:thinking" })
    local worktree = mock_fresh_implement_worktree(nil, current_base_pin, stale_branch_pin)
    mock_cache_command()
    mock_successful_candidate(event)

    local result = run_implement(event, opts("implement-cache-preparation-order"))

    t.eq(result.exit_code, 0)
    local pin_refresh = command_index("commit -m 'chore: refresh fkst-substrate pin'")
    local preparation = command_index(cache_command)
    local codex = command_index("codex exec")
    t.is_true(pin_refresh ~= nil)
    t.is_true(preparation ~= nil)
    t.is_true(codex ~= nil)
    t.is_true(pin_refresh < preparation)
    t.is_true(preparation < codex)
    t.eq(count_calls(cache_command), 1)
    local preparation_call = command_call(cache_command)
    t.eq(preparation_call.cwd, ".")
    t.eq(command_env(preparation_call, "FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE"), worktree)
  end,

  test_cache_preparation_unset_preserves_implementation_flow = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready", "fkst-dev:thinking" })
    mock_fresh_implement_worktree()
    mock_cache_command_unset()
    mock_successful_candidate(event)

    local result = run_implement(event, opts("implement-cache-preparation-unset"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls(cache_command), 0)
    t.eq(count_calls("codex exec"), 1)
  end,

  test_cache_preparation_failure_stops_before_codex_and_propagates = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready", "fkst-dev:thinking" })
    mock_fresh_implement_worktree()
    mock_cache_command({
      stdout = "",
      stderr = "cache seed failed",
      exit_code = 7,
    })

    local result = run_implement(event, opts("implement-cache-preparation-failure"))

    t.eq(result.exit_code, 1)
    t.eq(count_calls(cache_command), 1)
    t.eq(count_calls("codex exec"), 0)
    t.eq(#result.raises, 0)
    t.is_true(tostring(result.error):find("cache-preparation-failed", 1, true) ~= nil)
  end,

  test_cache_preparation_runs_for_reused_worktree_cache = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" })
    local worktree = mock_existing_empty_implement_worktree_reuse(nil, branch, "1")
    mock_cache_command()
    mock_implement_codex(0, "committed implementation from warm cache")
    mock_git_status("")
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    t.mock_command("rev-list --count", {
      stdout = "1\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = "def456\n",
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-reused-worktree-cache-preparation"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("git worktree add"), 0)
    t.eq(count_calls(cache_command), 1)
    t.eq(count_calls("codex exec"), 1)
    t.is_true(command_index(cache_command) < command_index("codex exec"))
    local preparation_call = command_call(cache_command)
    t.eq(preparation_call.cwd, ".")
    t.eq(command_env(preparation_call, "FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE"), worktree)
  end,
}
