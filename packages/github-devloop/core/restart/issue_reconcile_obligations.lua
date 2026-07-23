local restart_obligations = require("devloop.restart_obligations")

local OWNER = "github-devloop"
local EDGE_ID = "github-devloop/thinking/entry/issue_reconcile_true_stall"
local WITNESS_PREFIX = "migration/intent_bounded_replay/corpus/issue-reconcile.json#"

local function payload_obligations(effect_ids)
  local result = {}
  for _, effect_id in ipairs(effect_ids) do
    result[#result + 1] = {
      effect_id = effect_id,
      equality = "byte-exact-frozen-old",
    }
  end
  return result
end

local function obligation(fixture_id, decision, effect_ids)
  return {
    obligation_id = OWNER .. "/issue-reconcile/" .. fixture_id,
    owner = OWNER,
    edge_id = EDGE_ID,
    case_kind = "cas-matrix",
    input_fixture_id = fixture_id,
    expected_decision = decision,
    expected_effect_ids = effect_ids,
    expected_payload_obligations = payload_obligations(effect_ids),
    witness_id = WITNESS_PREFIX .. fixture_id,
  }
end

return restart_obligations.define({
  obligation("source-equal-apply", {
    cas_status = "apply",
    reason_code = "apply",
    cas_outcome = "applied",
  }, {
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_label_request",
  }),
  obligation("source-marker-missing-pending", {
    cas_status = "pending",
    reason_code = "source-marker-not-visible",
    cas_outcome = "retry-pending(from-state marker not yet visible)",
  }, {}),
  obligation("source-state-advanced-stale", {
    cas_status = "stale",
    reason_code = "advanced-or-diverged",
    cas_outcome = "skip-advanced-or-diverged",
  }, {}),
  obligation("target-idempotent", {
    cas_status = "idempotent",
    reason_code = "already-at-target",
    cas_outcome = "skip-idempotent(already at to_state)",
  }, {}),
})
