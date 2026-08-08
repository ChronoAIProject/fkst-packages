local catalog = require("devloop.restart_cas_catalog")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local restart_authority = require("core.restart_authority")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)

local OWNER = core.restart_package_name
local POLICY_ID = "cas.legacy_observe_issue_entry_v1"
local V_EQUAL = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local ISSUE_V_EQUAL = "owner/repo#issue#42@2026-06-03T01:02:03Z"

return {
  test_observe_issue_entry_illegal_apply_from_non_declared_source_is_rejected_after_resolve = function()
    local original_resolve = catalog.resolve
    local resolve_called = false
    catalog.resolve = function(policy_id, evidence, candidate_projection)
      resolve_called = true
      t.eq(policy_id, POLICY_ID, "illegal apply: resolved policy")
      t.eq(evidence.current.state, "declined", "illegal apply: resolved current state")
      t.eq(type(candidate_projection), "table", "illegal apply: owner projection shape")
      t.eq(candidate_projection.unmanaged.thinking, true, "illegal apply: owner projection unmanaged edge")
      t.eq(#owner_pending_projection.owner_errors(OWNER, candidate_projection), 0,
        "illegal apply: owner projection validity")
      return {
        status = "apply",
        reason_code = "apply",
        cas_outcome = "applied",
      }
    end
    local ok, decision = pcall(function()
      local sealed_snapshot = restart_authority.seal_snapshot({
        owner = OWNER,
        current = { state = "declined", version = V_EQUAL },
      })
      return restart_authority.decide_transition(sealed_snapshot, {
        semantic_variant = "unmanaged_issue",
        source_boundary = "github-proxy.github_entity_changed",
        target = "thinking",
        incoming_version = ISSUE_V_EQUAL,
      })
    end)
    catalog.resolve = original_resolve
    if not ok then
      error(decision, 0)
    end
    t.eq(resolve_called, true, "illegal apply: catalog resolves before source admission")
    t.eq(decision.status, "illegal", "illegal apply: status")
    t.eq(decision.reason_code, "source-state-not-admitted", "illegal apply: reason")
    t.eq(decision.cas_outcome, "illegal(source-state-not-admitted)", "illegal apply: CAS outcome")
  end,
}
