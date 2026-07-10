local fix_rounds = require("core.fix_rounds")
local parsers_misc = require("devloop.parsers.misc")

local C = {}

function C.admit(merge_ready, current_state, current_pr, source_ref, reason, classification)
  local ctx = {
    dept = "merge",
    from_state = "merge-ready",
    proposal_id = merge_ready.proposal_id,
    review_proposal_id = merge_ready.review_proposal_id,
    review_dedup_key = merge_ready.review_dedup_key,
    pr_number = merge_ready.pr_number,
    source_ref = source_ref,
    reason = reason,
  }
  local own_ci_red = parsers_misc.is_ci_red_reason(reason)
  if own_ci_red and classification == nil then
    error("github-devloop: own-ci-admission-classification-required: own-CI repair requires a current classification")
  end
  if not own_ci_red and classification ~= nil then
    error("github-devloop: own-ci-admission-classification-misapplied: own-CI classification cannot authorize a non-own-CI repair")
  end
  if own_ci_red then
    return fix_rounds.admit_own_ci_continuation(current_state, classification, ctx)
  end
  ctx.bound_head_sha = current_pr.head_sha
  return fix_rounds.admit_or_terminate(current_state, ctx)
end

return C
