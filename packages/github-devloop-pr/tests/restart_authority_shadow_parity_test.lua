local devloop_state = require("devloop.state")
local h = require("tests.devloop_helpers")
local restart_authority = require("core.restart_authority")
local t = h.t

local OWNER = "github-devloop-pr"
local SEMANTIC_VARIANT = "approved"
local MERGE_COMPLETED_VARIANT = "merge-completed"
local MERGE_COMPLETED_POLICY_ID = "cas.legacy_merge_completion_v1"
local MERGE_COMPLETED_EDGE_ID = "github-devloop-pr/merging/autonomous/merge-completed"
local V_OLDER = "2026-06-02T01-02-03Z"
local V_EQUAL = "2026-06-03T01-02-03Z"
local V_NEWER = "2026-06-04T01-02-03Z"
local V_ORDERING_EQUAL_CURRENT = V_EQUAL .. "/loop/01"
local V_ORDERING_EQUAL_INCOMING = V_EQUAL .. "/loop/1"

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

local function legacy_merge_completion(current, incoming, overlay)
  local admitted = current.state == "merge-ready"
    or current.state == "merging"
    or current.state == "merged"
  if not admitted then
    return {
      status = "stale",
      reason_code = "from-state-mismatch",
      cas_outcome = "skip-stale(from-state-mismatch)",
    }
  end
  local status = devloop_state.cyclic_transition_status(
    current, { "merge-ready", "merging" }, "merged", incoming
  )
  if status == "apply" and tostring(current.version or "") ~= tostring(overlay or incoming or "") then
    return {
      status = "stale",
      reason_code = "version-mismatch",
      cas_outcome = "skip-stale(version-mismatch)",
    }
  end
  local outcome = devloop_state.cas_outcome(current, status, incoming)
  local reason = ({
    apply = "apply",
    idempotent = "already-at-target",
    pending = "source-marker-not-visible",
  })[status]
  if status == "stale" then
    reason = outcome == "skip-stale(incoming version < current marker version)"
      and "incoming-version-older" or "advanced-or-diverged"
  end
  return { status = status, reason_code = reason, cas_outcome = outcome }
end

local function assert_bidirectional(left, right, field, context)
  t.eq(left[field], right[field], context .. ": NEW->OLD " .. field)
  t.eq(right[field], left[field], context .. ": OLD->NEW " .. field)
end

return {
  test_merge_completed_shadow_is_bidirectionally_legacy_exact = function()
    local cases = {
      { name = "entry-state-apply", current = { state = "merge-ready", version = V_EQUAL }, incoming = V_EQUAL },
      { name = "same-attempt-merging-apply", current = { state = "merging", version = V_EQUAL }, incoming = V_EQUAL },
      { name = "already-merged-idempotent", current = { state = "merged", version = V_EQUAL }, incoming = V_EQUAL },
      { name = "newer-request-pending", current = { state = "merge-ready", version = V_OLDER }, incoming = V_NEWER },
      { name = "older-request-stale", current = { state = "merge-ready", version = V_EQUAL }, incoming = V_OLDER },
      {
        name = "ordering-equal-raw-mismatch",
        current = { state = "merging", version = V_ORDERING_EQUAL_CURRENT },
        incoming = V_ORDERING_EQUAL_INCOMING,
        overlay = V_ORDERING_EQUAL_INCOMING,
      },
      { name = "outside-closed-domain", current = { state = "reviewing", version = V_EQUAL }, incoming = V_EQUAL },
    }
    for _, case in ipairs(cases) do
      local overlay = case.overlay or case.incoming
      local legacy = legacy_merge_completion(case.current, case.incoming, overlay)
      local sealed = restart_authority.seal_snapshot({
        owner = OWNER,
        proposal_id = "github-devloop/issue/owner/repo/42",
        current = case.current,
      })
      local shadow = restart_authority.decide_transition(sealed, {
        semantic_variant = MERGE_COMPLETED_VARIANT,
        target = "merged",
        incoming_version = case.incoming,
        overlay_version = overlay,
      })
      assert_bidirectional(shadow, legacy, "status", case.name)
      assert_bidirectional(shadow, legacy, "reason_code", case.name)
      assert_bidirectional(shadow, legacy, "cas_outcome", case.name)
      t.eq(shadow.edge_id, MERGE_COMPLETED_EDGE_ID, case.name .. ": exact owner edge")
      t.eq(shadow.cas_policy_id, MERGE_COMPLETED_POLICY_ID, case.name .. ": closed OLD policy")
      t.eq(shadow.grant, nil, case.name .. ": grant consumption stays disabled")
      if shadow.status == "apply" then
        t.eq(shadow.effect_entitlement_id, MERGE_COMPLETED_EDGE_ID .. "/apply")
        t.eq(table.concat(shadow.granted_effect_ids, ","), "github-proxy.github_pr_comment_request")
      elseif shadow.status == "idempotent" then
        t.eq(shadow.effect_entitlement_id, MERGE_COMPLETED_EDGE_ID .. "/idempotent")
        t.eq(#shadow.granted_effect_ids, 0)
      else
        t.eq(shadow.effect_entitlement_id, nil)
        t.eq(shadow.granted_effect_ids, nil)
      end
    end
  end,

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
