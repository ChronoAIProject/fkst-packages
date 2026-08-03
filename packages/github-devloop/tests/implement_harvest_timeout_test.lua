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

local function local_iteration_marker(outcome)
  local pair = ({
    PASS = "PASS:NONE",
    SEMANTIC_FAIL = "FAIL:SEMANTIC",
    UNKNOWN = "UNKNOWN:UNKNOWN",
  })[outcome]
  if pair == nil then
    error("github-devloop test: unknown local iteration outcome " .. tostring(outcome))
  end
  return "FKST_LOCAL_ITERATION_RESULT:v2:" .. pair .. "\n"
end

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
  test_successful_committed_head_with_unknown_verification_is_checkpointed = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local checkpoint_head = "1111111111111111111111111111111111111111"
    for _ = 1, 2 do
      t.mock_command("scripts/run.sh test-affected", {
        stdout = "",
        stderr = local_iteration_marker("UNKNOWN") .. "verification unavailable\n",
        exit_code = 2,
      })
    end

    local outcome = harvest.after_codex_success(
      "owner/repo",
      42,
      event,
      "dev",
      branch,
      "abc123",
      "/tmp/fkst-packages-test/github-devloop/runtime/worktrees/committed-unknown",
      1,
      now() - 60,
      "implement/exec/committed-unknown",
      checkpoint_head
    )

    t.eq(outcome.kind, "implement-checkpoint")
    t.eq(outcome.head_sha, checkpoint_head)
    t.eq(outcome.outcome, "checkpointed: verification-indeterminate")
    t.is_true(tostring(outcome.detail):find("candidate_result=UNKNOWN", 1, true) ~= nil)
    t.is_true(tostring(outcome.detail):find("candidate_verification_attempt=2/2", 1, true) ~= nil)
    t.eq(count_calls("commit -m"), 0)
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
    t.is_true(add_call ~= nil and add_call < commit_call)
    t.is_true(commit_call ~= nil and commit_call < verification_call)
  end,
}
