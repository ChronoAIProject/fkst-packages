local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local ready = h.ready
local deterministic_branch_for = h.deterministic_branch_for
local mock_issue_implement = h.mock_issue_implement
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local count_calls = h.count_calls
local harvest = require("departments.implement.harvest")

local function last_command_call_index(needle)
  local found = nil
  for index, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(needle, 1, true) ~= nil then
      found = index
    end
  end
  return found
end

return {
  test_candidate_local_iteration_exports_base_for_configured_command = function()
    t.mock_command('printf %s "$FKST_DEVLOOP_LOCAL_TEST_COMMAND"', {
      stdout = "make preflight",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("make preflight", {
      stdout = "",
      stderr = "FKST_LOCAL_ITERATION_RESULT:v2:PASS:NONE\n",
      exit_code = 0,
    })

    harvest.local_iteration_check("/tmp/fkst worktree", "abc123")

    local call = t.command_calls()[#t.command_calls()]
    t.eq(call.rendered, "cd '/tmp/fkst worktree' && export BASE='abc123' && make preflight")
  end,

  test_dirty_failed_attempt_is_committed_before_verification_as_checkpoint = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local checkpoint_head = "1111111111111111111111111111111111111111"
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
    })
    mock_git_status(" M packages/github-devloop/core.lua\n")
    t.mock_command("rev-list --count", {
      stdout = "0\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("scripts/run.sh test-affected", {
      stdout = "",
      stderr = "local verification failed",
      exit_code = 1,
    })
    mock_git_commit(checkpoint_head, branch)

    local outcome = harvest.after_codex_failure(
      "owner/repo",
      42,
      event,
      "dev",
      branch,
      "abc123",
      "/tmp/fkst-packages-test/github-devloop/runtime/worktrees/dirty-timeout",
      1,
      now() - 10800,
      "implement/exec/dirty-timeout",
      "codex timed out"
    )

    t.eq(outcome.kind, "implement-checkpoint")
    t.eq(outcome.head_sha, checkpoint_head)
    t.eq(outcome.branch, branch)
    t.is_true(tostring(outcome.detail):find("local verification failed", 1, true) ~= nil)
    t.eq(count_calls("commit -m"), 1)
    local verification_call = last_command_call_index("scripts/run.sh test-affected")
    local add_call = last_command_call_index("add -A")
    local commit_call = last_command_call_index("commit -m")
    t.is_true(verification_call ~= nil)
    local verification = t.command_calls()[verification_call]
    t.is_true(verification.rendered:find("export BASE='abc123'", 1, true) ~= nil)
    t.is_true(add_call ~= nil and add_call < commit_call)
    t.is_true(commit_call ~= nil and commit_call < verification_call)
  end,
}
