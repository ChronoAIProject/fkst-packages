local consensus = require("consensus")
local v_validate_proposal = require("devloop.validators.validate_proposal")

local M = {}

local function copy_without_caller_lineage(proposal)
  local value = {}
  for key, field in pairs(proposal) do
    if key ~= "proposal_id" then
      value[key] = field
    end
  end
  return value
end

local function attach_caller_lineage(result, proposal_id)
  if type(result) ~= "table"
    or (result.status ~= "reached" and result.status ~= "converge") then
    error("devloop: consensus-call-invalid: consensus returned an unsupported result")
  end
  local value = {}
  for key, field in pairs(result) do
    value[key] = field
  end
  value.proposal_id = proposal_id
  return value
end

function M.reach(proposal)
  if not v_validate_proposal.validate_proposal(proposal) then
    error("devloop: consensus-call-invalid: invalid caller proposal")
  end
  return attach_caller_lineage(
    consensus.reach(copy_without_caller_lineage(proposal)),
    proposal.proposal_id
  )
end

return M
