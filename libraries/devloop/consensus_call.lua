local consensus = require("consensus")
local strings = require("contract.strings")

local M = {}

local function copy_for_consensus(proposal)
  local value = {}
  for key, field in pairs(proposal) do
    if key ~= "proposal_id" then
      value[key] = field
    end
  end
  value.dedup_key = proposal.effect_version or proposal.dedup_key
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
  if type(proposal) ~= "table" then
    return consensus.reach(proposal)
  end
  if proposal.schema == "consensus.proposal.v1"
    and not strings.is_path_safe_key(proposal.proposal_id, 200) then
    return nil
  end
  local result = consensus.reach(copy_for_consensus(proposal), {
    invocation_id = proposal.proposal_id,
  })
  if result == nil then
    return nil
  end
  return attach_caller_lineage(result, proposal.proposal_id)
end

return M
