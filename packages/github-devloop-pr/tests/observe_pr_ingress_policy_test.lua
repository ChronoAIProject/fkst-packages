-- The observe_pr first-seen PR edge only admits its declared ingress boundary
-- and routable source states.

local h = require("tests.devloop_helpers")
local restart_authority = require("core.restart_authority")
local t = h.t
local core = h.core

local SEMANTIC_VARIANT = "first_seen_pr"
local SOURCE_BOUNDARY = "github-proxy.github_entity_changed"
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function ingress_shadow(current_state, source_boundary)
  local sealed = restart_authority.seal_snapshot({
    owner = core.restart_package_name,
    proposal_id = PROPOSAL_ID,
    current = { state = current_state, version = V_EQUAL },
  })
  return restart_authority.decide_transition(sealed, {
    semantic_variant = SEMANTIC_VARIANT,
    source_boundary = source_boundary,
    target = "reviewing",
    incoming_version = V_EQUAL,
    overlay_version = V_EQUAL,
  })
end

local function assert_illegal(actual, reason_code, context)
  t.eq(actual.status, "illegal", context .. ": status")
  t.eq(actual.reason_code, reason_code, context .. ": reason code")
  t.eq(actual.cas_outcome, "illegal(" .. reason_code .. ")", context .. ": CAS outcome")
  t.eq(actual.grant, nil, context .. ": grant disabled")
end

return {
  test_observe_pr_ingress_shadow_requires_exact_source_boundary = function()
    assert_illegal(
      ingress_shadow("pr-open", nil),
      "source-boundary-mismatch",
      "observe-pr-ingress-missing-boundary"
    )
    assert_illegal(
      ingress_shadow("pr-open", "github-devloop-pr.devloop_observe_pr"),
      "source-boundary-mismatch",
      "observe-pr-ingress-wrong-boundary"
    )
  end,

  test_observe_pr_ingress_shadow_rejects_unroutable_current_state = function()
    assert_illegal(
      ingress_shadow("blocked", SOURCE_BOUNDARY),
      "source-state-not-admitted",
      "observe-pr-ingress-unroutable-source"
    )
  end,
}
