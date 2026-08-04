local marker_facts = require("devloop.markers.facts")

local M = {}

function M.linked_pr(child, child_ref)
  local comments = child and child.comments or {}
  local proposal_id = child_ref and child_ref.proposal_id
  return marker_facts.pr_delegation_fact(comments, proposal_id, nil)
    or marker_facts.pr_link_fact(comments, proposal_id)
end

function M.pr_is_merged(current_pr)
  if current_pr == nil then
    return false
  end
  if tostring(current_pr.state or ""):upper() == "MERGED" then
    return true
  end
  -- JSON null is a non-string sentinel in the SDK decoder, so it is not merge evidence.
  return type(current_pr.merged_at) == "string" and current_pr.merged_at ~= ""
end

function M.evidence(child, current_pr, child_ref)
  local link = M.linked_pr(child, child_ref)
  if link == nil then
    return {
      link = nil,
      marker = false,
      native = false,
      merged = false,
    }
  end
  local proposal_id = child_ref and child_ref.proposal_id
  local marker = marker_facts.merged_fact(
    child and child.comments or {},
    proposal_id,
    link.pr_number,
    nil
  ) ~= nil or marker_facts.merged_fact(
    current_pr and current_pr.comments or {},
    proposal_id,
    link.pr_number,
    nil
  ) ~= nil
  local native = M.pr_is_merged(current_pr)
  return {
    link = link,
    marker = marker,
    native = native,
    merged = marker or native,
  }
end

return M
