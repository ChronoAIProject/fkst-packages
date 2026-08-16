local entity_list_cache = require("devloop.entity_list_cache")
local m_claims = require("devloop.claims")
local gh_argv = require("testkit_internal.gh_argv_mock")

local M = {}
local poll_sequence = 0

function M.mock_bot(login, write_mode, write_reads)
  fkst.test.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = login or "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  fkst.test.mock_command('printf %s "$FKST_DEVLOOP_FORK_GRACE_HOURS"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, write_reads or 2 do
    fkst.test.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = write_mode or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

function M.count_calls(needle)
  local count = 0
  for _, call in ipairs(fkst.test.command_calls()) do
    if gh_argv.call_contains(call, needle) then
      count = count + 1
    end
  end
  return count
end

function M.claim_with_poll_epoch(core, dept, repo, issue_number, current, proposal_id)
  poll_sequence = poll_sequence + 1
  cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
  local recorded, poll_epoch = entity_list_cache.record_poll_epoch(
    repo,
    "claim-contract-" .. tostring(poll_sequence)
  )
  fkst.test.is_true(recorded)
  local admission, detail = m_claims.claim_admission_precheck(
    current,
    m_claims.claim_admission_inputs(current, repo, poll_epoch)
  )
  return m_claims.claim_issue_for_management(
    dept,
    repo,
    issue_number,
    current,
    proposal_id,
    admission,
    detail
  )
end

return M
