local entity_list_cache = require("devloop.entity_list_cache")
local m_claims = require("devloop.claims")

local M = {}
local poll_sequence = 0

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
    core,
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
