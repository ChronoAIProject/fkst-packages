local h = require("tests.devloop_core_helpers")
local restart_cas_catalog = require("devloop.restart_cas_catalog")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")

local core = h.core
local t = h.t
local restart_projection = owner_pending_projection.frozen_projection()

local function catalog_cyclic_status(current, source_states, target_state, incoming_version, target_version)
  return restart_cas_catalog.resolve("cas.base_cyclic_legacy_v1", {
    current = current,
    source_states = source_states,
    target_state = target_state,
    incoming_version = incoming_version,
    target_version = target_version,
  }, restart_projection).status
end

return {
  test_cyclic_transition_expectations_use_catalog = function()
    t.eq(catalog_cyclic_status({ state = nil, version = nil }, { "fixing" }, "reviewing", "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"), "pending")
    t.eq(catalog_cyclic_status({
      state = "fixing",
      version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    }, { "reviewing" }, "merge-ready", "ready-consensus-github-devloop-issue-owner-repo-42-2026-06-03T01-02-03Z"), "stale")
    t.eq(catalog_cyclic_status({
      state = "merge-ready",
      version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    }, { "reviewing" }, "fixing", "ready-consensus-github-devloop-issue-owner-repo-42-2026-06-03T01-02-03Z"), "apply")
    t.eq(catalog_cyclic_status({
      state = "reviewing",
      version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1",
    }, { "fixing" }, "reviewing", "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z", "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1"), "idempotent")
    t.eq(catalog_cyclic_status({
      state = "reviewing",
      version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    }, { "fixing" }, "reviewing", core.fix_version_from_review_version("ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"), "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/2"), "pending")
    t.eq(catalog_cyclic_status({
      state = "reviewing",
      version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/1",
    }, { "review-meta" }, "fixing", "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"), "stale")
  end,

  test_review_loop_round_version_orders_after_base_reviewing = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
    local review_loop_version = version .. "/review-loop/3"

    local current = core.current_state({
      core.state_marker(proposal_id, "reviewing", version),
      core.state_marker(proposal_id, "review-meta", review_loop_version),
    }, proposal_id)

    t.eq(core.version_review_loop_round(review_loop_version), 3)
    t.eq(current.state, "review-meta")
    t.eq(current.version, review_loop_version)
    t.eq(catalog_cyclic_status(current, { "reviewing" }, "review-meta", version), "stale")
  end,
}
