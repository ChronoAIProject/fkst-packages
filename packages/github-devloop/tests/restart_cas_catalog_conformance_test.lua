local catalog = require("devloop.restart_cas_catalog")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local h = require("tests.devloop_helpers")

local t = h.t
local projection = owner_pending_projection.frozen_projection()
local ARTIFACT = "migration/restart-lifecycle.inventory.json"
local V_OLDER = "ready/cas-parity/loop/1"
local V_EQUAL = "ready/cas-parity/loop/2"
local V_NEWER = "ready/cas-parity/loop/3"

local policy_ids = {
  "cas.base_plain_legacy_v1",
  "cas.base_versioned_legacy_v1",
  "cas.base_cyclic_legacy_v1",
  "cas.legacy_loop_plain_v1",
  "cas.legacy_consensus_result_v1",
  "cas.legacy_issue_reconcile_v1",
  "cas.legacy_timeout_reconcile_v1",
  "cas.legacy_observe_issue_entry_v1",
  "cas.legacy_awaiting_pr_v1",
  "cas.legacy_observe_pr_v1",
  "cas.legacy_observe_pr_fix_v1",
  "cas.legacy_review_result_v1",
  "cas.legacy_fix_v1",
  "cas.legacy_review_meta_v1",
  "cas.legacy_merge_v1",
  "cas.legacy_merge_completion_v1",
  "cas.legacy_pr_fix_reconcile_v1",
  "cas.legacy_review_loop_safe_v1",
  "cas.legacy_review_activation_handoff_v1",
  "cas.legacy_implement_activation_handoff_v1",
}

local function assert_result(actual, status, reason_code, cas_outcome)
  t.eq(actual.status, status)
  t.eq(actual.reason_code, reason_code)
  t.eq(actual.cas_outcome, cas_outcome)
end

return {
  test_catalog_is_closed_and_points_only_to_the_protected_baseline = function()
    local actual = catalog.policy_ids()
    t.eq(#actual, #policy_ids)
    for index, policy_id in ipairs(policy_ids) do
      t.eq(actual[index], policy_id)
      local definition = catalog.definition(policy_id)
      t.eq(definition.id, policy_id)
      t.eq(type(definition.evidence_type), "string")
      t.eq(definition.production.artifact, ARTIFACT)
      t.eq(definition.production.schema, "restart-old-behavior-observation.v2")
      t.eq(type(definition.production.surface), "string")
    end
  end,

  test_base_policies_preserve_the_protected_edge_cases = function()
    assert_result(catalog.resolve("cas.base_plain_legacy_v1", {
      current = { state = "thinking", version = V_EQUAL },
      source_states = { "thinking" }, target_state = "ready",
    }, projection), "apply", "apply", "applied")

    assert_result(catalog.resolve("cas.base_versioned_legacy_v1", {
      current = { state = "thinking", version = V_EQUAL },
      source_states = { "thinking" }, target_state = "ready", incoming_version = V_NEWER,
    }, projection), "apply", "apply", "applied")

    assert_result(catalog.resolve("cas.base_cyclic_legacy_v1", {
      current = { state = "reviewing", version = V_EQUAL },
      source_states = { "reviewing" }, target_state = "fixing", incoming_version = V_NEWER,
    }, projection), "pending", "source-marker-not-visible", "retry-pending(from-state marker not yet visible)")

    assert_result(catalog.resolve("cas.base_cyclic_legacy_v1", {
      current = { state = "reviewing", version = V_EQUAL },
      source_states = { "reviewing" }, target_state = "fixing", incoming_version = V_OLDER,
    }, projection), "stale", "incoming-version-older", "skip-stale(incoming version < current marker version)")
  end,

  test_unknown_policy_fails_closed = function()
    assert_result(catalog.resolve("cas.unknown", {}, projection),
      "illegal", "unknown-cas-policy", "illegal(unknown-cas-policy)")
  end,
}
