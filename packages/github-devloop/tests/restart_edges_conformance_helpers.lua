local h = require("tests.devloop_core_helpers")
local entry_inventory = require("core.restart.entry_inventory")
local restart_cas_catalog = require("devloop.restart_cas_catalog")
local restart_edges = require("devloop.restart_edges")

local expected_successor_kinds = {
  ["awaiting-pr/awaiting_pr_to_merged"] = "guard_boundary",
  ["awaiting-pr/awaiting_pr_to_ready"] = "guard_boundary",
  ["awaiting-pr/awaiting_pr_to_blocked"] = "guard_boundary",
  ["dependency_wait/blockers_still_open"] = "guard_boundary",
  ["dependency_wait/blockers_released"] = "guard_boundary",
  ["dependency_wait/dependency_resolver_stale"] = "guard_boundary",
  ["implementing/revision_published"] = "autonomous",
  ["implementing/precursor_waiting"] = "autonomous",
  ["implementing/implementation_refused"] = "autonomous",
  ["implementing/revision_failed"] = "autonomous",
  ["implementation-escalating/child_dependencies_pending"] = "autonomous",
  ["implementation-escalating/child_dependencies_satisfied"] = "autonomous",
  ["ready/blocker_reappeared"] = "guard_boundary",
  ["ready/actionable_kickoff_timeout"] = "timeout",
  ["thinking/consensus-reached"] = "autonomous",
  ["thinking/consensus-reached-dependency-held"] = "autonomous",
  ["thinking/premise-refuted"] = "autonomous",
  ["thinking/consensus-stalled"] = "autonomous",
}

local expected_real_cas_by_id = {
  ["github-devloop/implementing/autonomous/revision_published"] = {
    cas_policy_id = "cas.legacy_awaiting_pr_v1",
    cas_variant = "implementing_to_awaiting_pr",
  },
  ["github-devloop/thinking/autonomous/consensus-reached"] = {
    cas_policy_id = "cas.legacy_consensus_result_v1",
    cas_variant = "thinking_to_ready",
  },
  ["github-devloop/thinking/autonomous/premise-refuted"] = {
    cas_policy_id = "cas.legacy_consensus_result_v1",
    cas_variant = "thinking_to_declined",
  },
  ["github-devloop/thinking/autonomous/consensus-stalled"] = {
    cas_policy_id = "cas.legacy_loop_plain_v1",
    cas_variant = "thinking_to_blocked",
  },
  ["github-devloop/ready/timeout/actionable_kickoff_timeout"] = {
    cas_policy_id = "cas.legacy_timeout_reconcile_v1",
    cas_variant = "ready_to_blocked",
  },
}

local expected_guard_boundary_cas_by_id = {
  ["github-devloop/awaiting-pr/guard_boundary/awaiting_pr_to_merged"] = {
    cas_policy_id = "cas.legacy_awaiting_pr_v1",
    cas_variant = "awaiting_pr_to_merged",
  },
  ["github-devloop/awaiting-pr/guard_boundary/awaiting_pr_to_ready"] = {
    cas_policy_id = "cas.legacy_awaiting_pr_v1",
    cas_variant = "awaiting_pr_to_ready",
  },
  ["github-devloop/awaiting-pr/guard_boundary/awaiting_pr_to_blocked"] = {
    cas_policy_id = "cas.legacy_awaiting_pr_v1",
    cas_variant = "awaiting_pr_to_blocked",
  },
}

return require("testkit_internal.restart_edges_conformance_fixtures").new({
  h = h,
  entry_inventory = entry_inventory,
  restart_cas_catalog = restart_cas_catalog,
  restart_edges = restart_edges,
  expectations = {
    successor_kinds = expected_successor_kinds,
    real_cas_by_id = expected_real_cas_by_id,
    public_guard_boundary_cas_by_id = expected_guard_boundary_cas_by_id,
    guard_boundary_cas_by_id = expected_guard_boundary_cas_by_id,
    timeout_cas_by_id = expected_real_cas_by_id,
  },
})
