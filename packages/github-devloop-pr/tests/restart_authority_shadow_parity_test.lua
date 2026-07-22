local h = require("tests.devloop_helpers")
local restart_authority = require("core.restart_authority")
local t = h.t

local OWNER = "github-devloop-pr"
local SEMANTIC_VARIANT = "approved"
local V_EQUAL = "2026-06-03T01-02-03Z"

local function sealed_snapshot()
  return restart_authority.seal_snapshot({
    owner = OWNER,
    proposal_id = "github-devloop/issue/owner/repo/42",
    current = { state = "reviewing", version = V_EQUAL },
  })
end

local function assert_illegal(actual, reason_code, cas_outcome, context)
  t.eq(actual.status, "illegal", context .. ": status")
  t.eq(actual.reason_code, reason_code, context .. ": reason code")
  t.eq(actual.cas_outcome, cas_outcome, context .. ": CAS outcome")
  t.eq(actual.grant, nil, context .. ": grant disabled")
end

return {
  test_shadow_decider_rejects_unsealed_snapshot = function()
    local actual = restart_authority.decide_transition({
      owner = OWNER,
      current = { state = "reviewing", version = V_EQUAL },
    }, {
      semantic_variant = SEMANTIC_VARIANT,
      incoming_version = V_EQUAL,
      overlay_version = V_EQUAL,
    })
    assert_illegal(
      actual,
      "unsealed-or-foreign-snapshot",
      "illegal(unsealed)",
      "unsealed snapshot"
    )
  end,

  test_shadow_decider_rejects_unknown_semantic_variant = function()
    local actual = restart_authority.decide_transition(sealed_snapshot(), {
      semantic_variant = "unknown-shadow-variant",
      incoming_version = V_EQUAL,
      overlay_version = V_EQUAL,
    })
    assert_illegal(actual, "unknown-variant", "illegal(unknown-variant)", "unknown variant")
  end,

  test_shadow_decider_requires_cyclic_incoming_version = function()
    local actual = restart_authority.decide_transition(sealed_snapshot(), {
      semantic_variant = SEMANTIC_VARIANT,
      overlay_version = V_EQUAL,
    })
    assert_illegal(
      actual,
      "incoming-version-required",
      "illegal(incoming-version-required)",
      "missing cyclic incoming version"
    )
  end,
}
