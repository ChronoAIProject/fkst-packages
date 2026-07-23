local restart_obligations = require("devloop.restart_obligations")

local OWNER = "github-devloop-pr"
local EDGE_ID = OWNER .. "/reviewing/entry/review_reconcile_true_stall"
local WITNESS_PREFIX = "migration/restart-lifecycle.inventory.json#"

local function obligation(fixture_id, observation_id, decision, effect_ids)
  local payloads = {}
  for _, effect_id in ipairs(effect_ids) do
    payloads[#payloads + 1] = {
      effect_id = effect_id,
      equality = "byte-exact-frozen-old",
    }
  end
  return {
    obligation_id = OWNER .. "/review-reconcile/" .. fixture_id,
    owner = OWNER,
    edge_id = EDGE_ID,
    case_kind = "cas-matrix",
    input_fixture_id = fixture_id,
    expected_decision = decision,
    expected_effect_ids = effect_ids,
    expected_payload_obligations = payloads,
    witness_id = WITNESS_PREFIX .. observation_id,
  }
end

return restart_obligations.define({
  obligation(
    "apply",
    "writer:github-devloop-pr:reconcile-reviewing-blocked/blocked/apply/apply/blocked",
    {
      cas_status = "apply",
      reason_code = "apply",
      cas_outcome = "applied",
      frozen_status = "apply",
      frozen_reason_code = "apply",
      frozen_cas_outcome = "applied",
    },
    {
      "github-proxy.github_pr_comment_request",
      "github-proxy.github_issue_label_request",
    }
  ),
  obligation(
    "already-terminal",
    "writer:github-devloop-pr:reconcile-reviewing-blocked/blocked/skip-idempotent(already terminal)/already-terminal/none",
    {
      cas_status = "idempotent",
      reason_code = "already-at-target",
      cas_outcome = "skip-idempotent(already at to_state)",
      frozen_status = "skip-idempotent(already terminal)",
      frozen_reason_code = "already-terminal",
      frozen_cas_outcome = "skip-idempotent(already terminal)",
    },
    {}
  ),
  obligation(
    "review-reconcile-marker-visible",
    "writer:github-devloop-pr:reconcile-reviewing-blocked/blocked/skip-idempotent(review reconcile marker already visible)/review-reconcile-marker-visible/none",
    {
      cas_status = "idempotent",
      reason_code = "already-at-target",
      cas_outcome = "skip-idempotent(already at to_state)",
      frozen_status = "skip-idempotent(review reconcile marker already visible)",
      frozen_reason_code = "review-reconcile-marker-visible",
      frozen_cas_outcome = "skip-idempotent(review reconcile marker already visible)",
    },
    {}
  ),
  obligation(
    "state-advanced",
    "writer:github-devloop-pr:reconcile-reviewing-blocked/blocked/skip-stale(state-advanced)/state-advanced/none",
    {
      cas_status = "stale",
      reason_code = "incoming-version-older",
      cas_outcome = "skip-stale(incoming version < current marker version)",
      frozen_status = "skip-stale(state-advanced)",
      frozen_reason_code = "state-advanced",
      frozen_cas_outcome = "skip-stale(state-advanced)",
    },
    {}
  ),
})
