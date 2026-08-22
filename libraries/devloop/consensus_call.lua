local consensus = require("consensus")
local devloop_base = require("devloop.base")
local entity = require("devloop.entity")
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

local function target_proposal_id(source_ref)
  local repo, pr_number = devloop_base.parse_pr_source_ref(source_ref)
  if repo == nil then
    return nil
  end
  return entity.pr_proposal_id(repo, pr_number)
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
    target_proposal_id = target_proposal_id(proposal.source_ref),
  })
  if result == nil then
    return nil
  end
  return attach_caller_lineage(result, proposal.proposal_id)
end

return M
