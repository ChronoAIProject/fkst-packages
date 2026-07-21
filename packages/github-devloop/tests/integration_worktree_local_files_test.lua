local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local gh_argv = require("testkit_internal.gh_argv_mock")

local function command_index(fragment)
  for index, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(fragment, 1, true) ~= nil then
      return index
    end
  end
  return nil
end

return {
  test_implement_hydrates_declared_local_files_before_codex = function()
    local event = h.ready()
    h.mock_issue_implement({ "fkst-dev:ready" }, {
      core.state_marker(event.proposal_id, "ready", event.dedup_key),
    })
    local worktree = h.mock_fresh_implement_worktree()
    t.mock_command('printf %s "$FKST_WORKTREE_LOCAL_FILES"', {
      stdout = "apps/console/.env.local\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_HOST_ROOT"', {
      stdout = "/tmp/fkst-host",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_PLATFORM_ROOT"', {
      stdout = "/tmp/fkst-packages",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("hydrate_worktree_local_files.py", {
      stdout = "hydrated 1 worktree local file\n",
      stderr = "",
      exit_code = 0,
    })
    h.mock_implement_codex(0, "No files needed changes.")
    h.mock_git_status("")
    t.mock_command("rev-list --count", {
      stdout = "0\n",
      stderr = "",
      exit_code = 0,
    })

    local result = h.run_implement(event, h.opts("implement-worktree-local-files"))

    t.eq(result.exit_code, 0)
    local hydration_index = command_index("hydrate_worktree_local_files.py")
    local codex_index = command_index("codex exec")
    t.is_true(hydration_index ~= nil)
    t.is_true(codex_index ~= nil)
    t.is_true(hydration_index < codex_index)
    local hydration_call = t.command_calls()[hydration_index]
    t.is_true(hydration_call.rendered:find(worktree, 1, true) ~= nil)
    t.eq(gh_argv.count_calls(t, "git worktree add"), 1)
  end,
}
