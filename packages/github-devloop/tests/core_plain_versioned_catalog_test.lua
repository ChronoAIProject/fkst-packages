local h = require("tests.devloop_core_helpers")
local conv_reconcile = require("devloop.convergence.reconcile")
local restart_cas_catalog = require("devloop.restart_cas_catalog")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")

local core = h.core
local t = h.t
local restart_projection = owner_pending_projection.frozen_projection()

local function catalog_status(policy_id, current, source_states, target_state, incoming_version)
  return restart_cas_catalog.resolve(policy_id, {
    current = current,
    source_states = source_states,
    target_state = target_state,
    incoming_version = incoming_version,
  }, restart_projection).status
end

local function catalog_plain_status(current_state, source_states, target_state)
  local current = current_state == nil and nil or { state = current_state }
  return catalog_status("cas.base_plain_legacy_v1", current, source_states, target_state)
end

local function catalog_versioned_status(current, source_states, target_state, incoming_version)
  return catalog_status(
    "cas.base_versioned_legacy_v1",
    current,
    source_states,
    target_state,
    incoming_version
  )
end

return {
  test_plain_and_versioned_transition_expectations_use_catalog = function()
    t.eq(catalog_plain_status("thinking", { "thinking" }, "ready"), "apply")
    t.eq(catalog_plain_status("ready", { "thinking" }, "ready"), "idempotent")
    t.eq(catalog_plain_status(nil, { "thinking" }, "ready"), "pending")
    t.eq(catalog_plain_status("implementing", { "thinking" }, "ready"), "stale")
    local versioned_current = {
      state = "ready",
      version = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z",
    }
    t.eq(catalog_versioned_status(versioned_current, { "thinking" }, "ready", "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"), "stale")
    t.eq(catalog_versioned_status(versioned_current, { "ready" }, "implementing", "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"), "apply")
    local ready_current = {
      state = "ready",
      version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z",
    }
    t.eq(catalog_versioned_status(ready_current, { "ready" }, "implementing", "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"), "stale")
  end,

  test_ready_marker_wins_same_version_tie_and_allows_catalog_implement_cas = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"

    local current = core.current_state({
      core.state_marker(proposal_id, "ready", version),
      core.state_marker(proposal_id, "thinking", version),
    }, proposal_id)
    t.eq(core.stage_rank("ready") > core.stage_rank("thinking"), true)
    t.eq(current.state, "ready")
    t.eq(current.version, version)
    t.eq(current.stage_rank, core.stage_rank("ready"))

    local transition = catalog_versioned_status(current, { "ready" }, "implementing", version)
    t.eq(transition, "apply")
    t.eq(core.cas_outcome(current, transition, version), "applied")
  end,

  test_consensus_loop_result_orders_after_answered_intake_marker = function()
    local intake_version = "github-devloop/issue/owner/repo/42/intake/2485289059"
    local consensus_version = "consensus:" .. intake_version .. "/loop/5"
    local current = {
      state = "thinking",
      version = intake_version,
    }

    t.eq(catalog_versioned_status(current, { "thinking" }, "ready", consensus_version), "apply")
    t.eq(core.compare_state_marker_order(current, "ready", consensus_version), -1)
    t.eq(core.current_state({
      core.state_marker("github-devloop/issue/owner/repo/42", "thinking", intake_version),
      core.state_marker("github-devloop/issue/owner/repo/42", "ready", consensus_version),
    }, "github-devloop/issue/owner/repo/42").state, "ready")
  end,

  test_terminal_reconcile_versions_apply_through_catalog = function()
    local live_thinking_version = "github-devloop/issue/owner/repo/42/2026-06-14T05-22-55Z/intake/1287859418"
    local terminal_version = conv_reconcile.reconcile_terminal_state_version(live_thinking_version, 3)
    t.eq(catalog_versioned_status({ state = "thinking", version = live_thinking_version }, { "thinking" }, "blocked", terminal_version), "apply")

    local live_higher_loop = live_thinking_version .. "/loop/8"
    local higher_terminal = conv_reconcile.reconcile_terminal_state_version(live_higher_loop, 3)
    t.eq(catalog_versioned_status({ state = "thinking", version = live_higher_loop }, { "thinking" }, "blocked", higher_terminal), "apply")

    local live_reviewing_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/9"
    local review_terminal_version = conv_reconcile.review_reconcile_terminal_state_version(live_reviewing_version, 3)
    t.eq(catalog_versioned_status({ state = "reviewing", version = live_reviewing_version }, { "reviewing" }, "blocked", review_terminal_version), "apply")
  end,
}
