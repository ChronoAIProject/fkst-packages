local restart_obligations = require("devloop.restart_obligations")

local OWNER = "github-devloop"
local EDGE_ID = "github-devloop/ready/timeout/actionable_kickoff_timeout"
local WITNESS_PREFIX = "migration/intent_bounded_replay/corpus/timeout-reconcile.json#"

local function payload_obligations(effect_ids)
  local result = {}
  for _, effect_id in ipairs(effect_ids) do
    table.insert(result, {
      effect_id = effect_id,
      equality = "byte-exact-frozen-old",
    })
  end
  return result
end

local function obligation(fixture_id, decision, effect_ids)
  return {
    obligation_id = OWNER .. "/timeout-reconcile/" .. fixture_id,
    owner = OWNER,
    edge_id = EDGE_ID,
    case_kind = "timeout",
    input_fixture_id = fixture_id,
    expected_decision = decision,
    expected_effect_ids = effect_ids,
    expected_payload_obligations = payload_obligations(effect_ids),
    witness_id = WITNESS_PREFIX .. fixture_id,
  }
end

return restart_obligations.define({
  obligation("newer-source-marker-missing-pending", {
    cas_status = "pending",
    reason_code = "source-marker-not-visible",
    cas_outcome = "retry-pending(from-state marker not yet visible)",
  }, {}),
  obligation("source-equal-apply", {
    cas_status = "apply",
    reason_code = "apply",
    cas_outcome = "applied",
  }, {
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_label_request",
  }),
  obligation("source-older-stale", {
    cas_status = "stale",
    reason_code = "incoming-version-older",
    cas_outcome = "skip-stale(incoming version < current marker version)",
  }, {}),
})
