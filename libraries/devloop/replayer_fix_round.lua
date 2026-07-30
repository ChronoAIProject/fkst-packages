local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local fix_round_authority = require("devloop.fix_round_authority")
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_logging = require("devloop.logging")

local M = {}

function M.next_version_or_reconcile(dept, issue, state, proposal_id, pr_number, review, head_sha, source_ref, reason)
  local transition = fix_round_authority.next_or_decompose(state.version)
  if transition.kind == "advance" then
    return transition.version
  end
  local binding = review or {}
  local bound_head = head_sha or binding.reviewed_head_sha
  local review_proposal_id = binding.review_proposal_id
    or devloop_base.pr_review_proposal_id(issue.repo, pr_number, state.version, bound_head)
  local review_dedup_key = devloop_base.canonical_pr_review_consensus_dedup_for_proposal(
    binding.review_dedup_key,
    review_proposal_id
  ) or devloop_base.pr_review_consensus_dedup_key(review_proposal_id)
  local payload = conv_reconcile.build_devloop_fix_reconcile_payload({
    proposal_id = proposal_id,
    review_proposal_id = review_proposal_id,
    review_dedup_key = review_dedup_key,
    reviewed_head_sha = bound_head,
    pr_number = pr_number,
    source_ref = source_ref or entity_lib.pr_source_ref(issue.repo, pr_number),
  }, transition.version)
  devloop_logging.log_cas_decision(
    dept,
    proposal_id,
    state,
    state.state,
    "blocked",
    "applied(fix-loop-max-rounds)",
    reason
  )
  devloop_logging.log_raise(dept, proposal_id, "devloop_fix_reconcile", payload)
  return nil
end

return M
