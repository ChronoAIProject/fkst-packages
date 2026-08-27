local h = require("tests.devloop_helpers")
local codex_jsonl = require("testkit_internal.codex_jsonl")
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
local mock_result_checkpoint = h.mock_result_checkpoint
local mock_branch_diff_paths = h.mock_branch_diff_paths
local mock_force_clean = h.mock_force_clean
local count_calls = h.count_calls

local cache_command = "scripts/warm_pinned_bin.sh"
local cache_command_env = 'printf %s "$FKST_DEVLOOP_CACHE_PREPARATION_COMMAND"'
local project_root_env = 'printf %s "$FKST_PROJECT_ROOT"'
local trusted_repository_root = "/trusted/repository"
local current_base_pin = "2222222222222222222222222222222222222222"
local stale_branch_pin = "1111111111111111111111111111111111111111"

local function mock_cache_command(result, invocation_count)
  for _ = 1, invocation_count or 1 do
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
    t.mock_command(project_root_env, {
      stdout = trusted_repository_root,
      stderr = "",
      exit_code = 0,
    })
  end
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

local function command_indices(needle)
  local indices = {}
  for index, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(needle, 1, true) ~= nil then
      table.insert(indices, index)
    end
  end
  return indices
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

local function mock_candidate_local_red()
  t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
    stdout = "",
    stderr = "FKST_LOCAL_ITERATION_RESULT:v2:FAIL:SEMANTIC\ncandidate failed\n",
    exit_code = 1,
  })
end

local function mock_codex_success_without_local_iteration(message)
  t.mock_command("codex exec", {
    stdout = codex_jsonl.final_message(message),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_base_probe(worktree)
  local base_probe = worktree .. "-base-probe"
  for _ = 1, 2 do
    mock_force_clean(base_probe)
  end
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("git worktree add --detach", {
    stdout = "Preparing worktree (detached HEAD abc123)\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("rev-parse HEAD", { stdout = "abc123\n", stderr = "", exit_code = 0 })
  t.mock_command("status --porcelain", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("ls-files", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("ls-tree", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("FKST_IMPLEMENTATION_WORKTREE_RESULT:v1:ENTERED", {
    stdout = "",
    stderr = "FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE\n",
    exit_code = 0,
  })
end

return {
  test_cache_preparation_runs_after_substrate_refresh_and_before_codex = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready", "fkst-dev:thinking" })
    local worktree = mock_fresh_implement_worktree(nil, current_base_pin, stale_branch_pin)
    mock_cache_command(nil, 2)
    mock_successful_candidate(event)

    local result = run_implement(event, opts("implement-cache-preparation-order"))

    t.eq(result.exit_code, 0)
    local pin_refresh = command_index("commit -m 'chore: refresh fkst-substrate pin'")
    local preparations = command_indices(cache_command)
    local codex = command_index("codex exec")
    local verification = command_index("scripts/run.sh test-affected")
    t.is_true(pin_refresh ~= nil)
    t.eq(#preparations, 2)
    t.is_true(codex ~= nil)
    t.is_true(verification ~= nil)
    t.is_true(pin_refresh < preparations[1])
    t.is_true(preparations[1] < codex)
    t.is_true(codex < preparations[2])
    t.is_true(preparations[2] < verification)
    t.eq(count_calls(cache_command), 2)
    local preparation_calls = {}
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find(cache_command, 1, true) ~= nil then
        table.insert(preparation_calls, call)
      end
    end
    for _, preparation_call in ipairs(preparation_calls) do
      t.eq(preparation_call.cwd, trusted_repository_root)
      t.eq(command_env(preparation_call, "FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE"), worktree)
    end
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

  test_cache_preparation_failure_after_codex_stops_before_staging = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready", "fkst-dev:thinking" })
    mock_fresh_implement_worktree()
    mock_cache_command(nil, 1)
    mock_cache_command({
      stdout = "",
      stderr = "target is not ignored",
      exit_code = 1,
    })
    mock_implement_codex(0, "implementation changed cache tracking")
    mock_git_status(" M .gitignore\n")

    local result = run_implement(event, opts("implement-cache-preparation-before-staging"))

    t.eq(result.exit_code, 1)
    t.eq(count_calls(cache_command), 2)
    t.eq(count_calls("add -A"), 1)
    t.eq(count_calls("commit -m 'Implement github-devloop ready state'"), 0)
    t.eq(count_calls("codex exec"), 1)
    t.is_true(tostring(result.error):find("cache-preparation-failed", 1, true) ~= nil)
  end,

  test_cache_preparation_runs_for_reused_worktree_cache = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" })
    local worktree = mock_existing_empty_implement_worktree_reuse(nil, branch, "1")
    mock_cache_command(nil, 2)
    mock_implement_codex(0, "committed implementation from warm cache")
    mock_git_status("")
    mock_branch_diff_paths("packages/github-devloop/core.lua\n")
    mock_result_checkpoint("def456", branch)
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
    t.eq(count_calls(cache_command), 2)
    t.eq(count_calls("codex exec"), 1)
    local preparations = command_indices(cache_command)
    t.is_true(preparations[1] < command_index("codex exec"))
    t.is_true(command_index("codex exec") < preparations[2])
    t.is_true(preparations[2] < command_index("scripts/run.sh test-affected"))
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find(cache_command, 1, true) ~= nil then
        t.eq(call.cwd, trusted_repository_root)
        t.eq(command_env(call, "FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE"), worktree)
      end
    end
  end,

  test_cache_preparation_covers_candidate_and_detached_base_without_reusing_verdicts = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready", "fkst-dev:thinking" })
    local worktree = mock_fresh_implement_worktree()
    mock_cache_command(nil, 4)
    mock_codex_success_without_local_iteration("implemented with a semantic regression")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("def456", branch)
    mock_candidate_local_red()
    mock_base_probe(worktree)

    local result = run_implement(event, opts("implement-cache-preparation-base-probe"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls(cache_command), 4)
    t.eq(count_calls("scripts/run.sh test-affected"), 2)
    local preparations = command_indices(cache_command)
    local verifications = command_indices("scripts/run.sh test-affected")
    t.is_true(preparations[1] < command_index("codex exec"))
    t.is_true(command_index("codex exec") < preparations[2])
    t.is_true(preparations[2] < preparations[3])
    t.is_true(preparations[3] < verifications[1])
    t.is_true(verifications[1] < preparations[4])
    t.is_true(preparations[4] < verifications[2])

    local preparation_worktrees = {}
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find(cache_command, 1, true) ~= nil then
        table.insert(preparation_worktrees,
          command_env(call, "FKST_DEVLOOP_CACHE_PREPARATION_WORKTREE"))
      end
    end
    t.eq(preparation_worktrees[1], worktree)
    t.eq(preparation_worktrees[2], worktree)
    t.eq(preparation_worktrees[3], worktree)
    t.is_true(tostring(preparation_worktrees[4]):find(worktree .. "-base-probe-", 1, true) ~= nil)
  end,
}
