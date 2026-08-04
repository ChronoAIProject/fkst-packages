local implementation_escalation = require("devloop.implementation_escalation")

local P = {}

function P.attach(request, ready, branch, attempt_result, escalation_evidence)
  if attempt_result ~= nil then
    request.body = request.body .. "\n" .. implementation_escalation.attempt_result_marker(attempt_result)
  end
  if escalation_evidence == nil then
    return request
  end

  request.body = request.body .. "\n"
    .. implementation_escalation.escalation_marker(
      ready.proposal_id,
      ready.dedup_key,
      escalation_evidence
    )
  request.handoff = implementation_escalation.build_payload({
    proposal_id = ready.proposal_id,
    version = ready.dedup_key,
    branch = branch,
    source_ref = ready.source_ref,
  }, escalation_evidence)
  request.handoff.kind = "github-devloop.implementation-escalation"
  return request
end

return P
