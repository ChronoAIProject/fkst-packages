local h = require("tests.devloop_core_helpers")
local entry_inventory = require("core.restart.entry_inventory")
local restart_cas_catalog = require("devloop.restart_cas_catalog")
local restart_edges = require("devloop.restart_edges")

local expected_successor_kinds = {
  ["fixing/revision_published"] = "autonomous",
  ["fixing/revision_failed"] = "autonomous",
  ["fixing/fix_budget_exhausted"] = "autonomous",
  ["merge-ready/fix_budget_exhausted"] = "autonomous",
  ["merging/merge-completed"] = "autonomous",
  ["merging/head-advanced"] = "autonomous",
  ["merging/merge-needs-fix"] = "autonomous",
  ["merging/fix_budget_exhausted"] = "autonomous",
  ["pr-open/review_requested"] = "autonomous",
  ["pr-open/not_mergeable_repair"] = "autonomous",
  ["pr-open/pr_base_unmanaged"] = "guard_boundary",
  ["review-meta/fix"] = "autonomous",
  ["review-meta/no-actionable-gap"] = "autonomous",
  ["review-meta/block"] = "autonomous",
  ["reviewing/approved"] = "autonomous",
  ["reviewing/changes_requested"] = "autonomous",
  ["reviewing/needs_review_meta"] = "autonomous",
  ["reviewing/watchdog_reconcile_terminal"] = "timeout",
}

local expected_real_cas_by_id = {
  ["github-devloop-pr/fixing/autonomous/revision_failed"] = {
    cas_policy_id = "cas.legacy_fix_v1",
    cas_variant = "fixing_to_review_meta",
  },
  ["github-devloop-pr/merge-ready/guard_boundary/merge_gate/code_repair_needed"] = {
    cas_policy_id = "cas.legacy_merge_v1",
    cas_variant = "merge_ready_to_fixing",
  },
  ["github-devloop-pr/merge-ready/guard_boundary/merge_gate/eligible_now"] = {
    cas_policy_id = "cas.legacy_merge_v1",
    cas_variant = "merge_ready_or_merging_to_merging",
  },
  ["github-devloop-pr/merging/autonomous/merge-completed"] = {
    cas_policy_id = "cas.legacy_merge_completion_v1",
    cas_variant = "merge_ready_or_merging_to_merged",
  },
  ["github-devloop-pr/merging/autonomous/merge-needs-fix"] = {
    cas_policy_id = "cas.legacy_merge_v1",
    cas_variant = "merging_to_fixing",
  },
  ["github-devloop-pr/pr-open/autonomous/not_mergeable_repair"] = {
    cas_policy_id = "cas.legacy_observe_pr_fix_v1",
    cas_variant = "pr_open_to_fixing",
  },
  ["github-devloop-pr/reviewing/timeout/watchdog_reconcile_terminal"] = {
    cas_policy_id = "cas.legacy_timeout_reconcile_v1",
    cas_variant = "reviewing_to_blocked",
  },
  ["github-devloop-pr/merge-ready/timeout/merge_gate/watchdog_reconcile_terminal"] = {
    cas_policy_id = "cas.legacy_timeout_reconcile_v1",
    cas_variant = "merge_ready_to_blocked",
  },
  ["github-devloop-pr/reviewing/autonomous/approved"] = {
    cas_policy_id = "cas.legacy_review_result_v1",
    cas_variant = "reviewing_to_merge_ready",
  },
  ["github-devloop-pr/reviewing/autonomous/changes_requested"] = {
    cas_policy_id = "cas.legacy_review_result_v1",
    cas_variant = "reviewing_to_fixing",
  },
  ["github-devloop-pr/reviewing/autonomous/needs_review_meta"] = {
    cas_policy_id = "cas.legacy_review_result_v1",
    cas_variant = "reviewing_to_review_meta",
  },
  ["github-devloop-pr/fixing/autonomous/revision_published"] = {
    cas_policy_id = "cas.legacy_fix_v1",
    cas_variant = "fixing_to_reviewing",
  },
  ["github-devloop-pr/review-meta/autonomous/fix"] = {
    cas_policy_id = "cas.legacy_review_meta_v1",
    cas_variant = "predecision_eligibility",
  },
  ["github-devloop-pr/review-meta/autonomous/no-actionable-gap"] = {
    cas_policy_id = "cas.legacy_review_meta_v1",
    cas_variant = "predecision_eligibility",
  },
  ["github-devloop-pr/review-meta/autonomous/block"] = {
    cas_policy_id = "cas.legacy_review_meta_v1",
    cas_variant = "predecision_eligibility",
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
    autonomous_cas_by_id = expected_real_cas_by_id,
    guard_boundary_cas_by_id = expected_real_cas_by_id,
    timeout_cas_by_id = expected_real_cas_by_id,
    guard_boundary_entitlements_required = true,
  },
})
