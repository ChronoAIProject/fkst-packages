local h = require("tests.devloop_core_helpers")
local restart_authority = require("core.restart_authority")
local restart_effects = require("core.restart_effects")

local t = h.t

local OWNER = "github-devloop-pr"
local EDGE_ID = "github-devloop-pr/reviewing/autonomous/changes_requested"
local APPLY_ENTITLEMENT_ID = EDGE_ID .. "/apply"
local IDEMPOTENT_ENTITLEMENT_ID = EDGE_ID .. "/idempotent"
local EFFECT_IDS = {
  "github-proxy.github_pr_comment_request",
  "github-proxy.github_issue_label_request",
}
local AUTHORITATIVE_SINK = "comment:pr:review-result"
local V_CURRENT = "2026-06-03T01-02-03Z"
local V_SAFE_CURRENT = "v-loop-01"
local V_SAFE_INCOMING = "v-loop-1"

local function snapshot(overrides)
  local fields = {
    owner = OWNER,
    entity = { kind = "pr", repo = "owner/repo", number = 7 },
    proposal_id = "github-devloop/issue/owner/repo/42",
    current = { state = "reviewing", version = V_CURRENT },
    snapshot_fingerprint = "snapshot:pr:7:v1",
    lock_epoch = "lock:pr:7:epoch:7",
    generation = "generation:7",
  }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  return restart_effects.seal_snapshot(fields)
end

local function decision(sealed_snapshot, status)
  local intent = {
    semantic_variant = "changes_requested",
    target = "fixing",
    incoming_version = V_CURRENT,
    overlay_version = V_CURRENT,
  }
  if status == "stale" then
    intent.incoming_version = V_SAFE_INCOMING
    intent.overlay_version = V_SAFE_INCOMING
  elseif status == "illegal" then
    intent = { semantic_variant = "not-a-canonical-variant" }
  end
  return restart_effects.decide_transition(sealed_snapshot, intent)
end

local function assert_array(actual, expected, context)
  t.eq(type(actual), "table", context .. ": array type")
  t.eq(#actual, #expected, context .. ": array length")
  for index, value in ipairs(expected) do
    t.eq(actual[index], value, context .. ": item " .. tostring(index))
  end
end

return {
  test_forged_plain_table_grant_and_analysis_decision_are_rejected = function()
    local sealed = snapshot()
    local decided = decision(sealed, "apply")
    local genuine = restart_effects.mint_grant(sealed, decided, AUTHORITATIVE_SINK)
    t.eq(type(genuine), "table")

    local forged = {}
    for key, value in pairs(genuine) do
      forged[key] = value
    end
    t.eq(restart_effects.verify_grant(forged, EFFECT_IDS[1]), false)

    local analysis_snapshot = snapshot({ snapshot_fingerprint = "snapshot:pr:7:analysis" })
    local analysis_source = decision(analysis_snapshot, "apply")
    local analysis_copy = {}
    for key, value in pairs(analysis_source) do
      analysis_copy[key] = value
    end
    t.eq(restart_effects.mint_grant(analysis_snapshot, analysis_copy, AUTHORITATIVE_SINK), nil)
  end,

  test_only_fresh_owner_sealed_snapshot_can_mint = function()
    local sealed = snapshot()
    local decided = decision(sealed, "apply")
    local plain = {
      owner = OWNER,
      entity = sealed.entity,
      current = sealed.current,
      snapshot_fingerprint = sealed.snapshot_fingerprint,
      lock_epoch = sealed.lock_epoch,
      generation = sealed.generation,
      _owner_snapshot_seal = sealed._owner_snapshot_seal,
    }
    local foreign_seal = restart_authority.seal_snapshot({
      owner = OWNER,
      proposal_id = sealed.proposal_id,
      current = sealed.current,
    })

    t.eq(restart_effects.mint_grant(plain, decided, AUTHORITATIVE_SINK), nil)
    t.eq(restart_effects.mint_grant(foreign_seal, decided, AUTHORITATIVE_SINK), nil)
    t.eq(type(restart_effects.mint_grant(sealed, decided, AUTHORITATIVE_SINK)), "table")
  end,

  test_apply_grant_is_exact_and_accepts_only_entitled_effects = function()
    local sealed = snapshot()
    local decided = decision(sealed, "apply")
    t.eq(decided.status, "apply")
    t.eq(decided.incoming_version, V_CURRENT, "decision carries the byte-exact incoming version")
    t.eq(decided.target_version, nil, "decision preserves an omitted target version")
    t.eq(decided.overlay_version, V_CURRENT, "decision carries the byte-exact overlay version")
    t.eq(decided.effect_entitlement_id, APPLY_ENTITLEMENT_ID)
    assert_array(decided.granted_effect_ids, EFFECT_IDS, "apply entitlement")

    local grant = restart_effects.mint_grant(sealed, decided, AUTHORITATIVE_SINK)
    t.eq(type(grant), "table")
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1]), true)
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[2]), true)
    t.eq(restart_effects.verify_grant(grant, "github-devloop-pr.devloop_fixing"), false)
  end,

  test_idempotent_complete_entitlement_mints_no_grant = function()
    local sealed = snapshot({
      current = { state = "fixing", version = V_CURRENT },
      snapshot_fingerprint = "snapshot:pr:7:fixing:v1",
    })
    local decided = decision(sealed, "idempotent")
    t.eq(decided.status, "idempotent")
    t.eq(decided.effect_entitlement_id, IDEMPOTENT_ENTITLEMENT_ID)
    assert_array(decided.granted_effect_ids, {}, "idempotent entitlement")
    t.eq(restart_effects.mint_grant(sealed, decided, AUTHORITATIVE_SINK), nil)
  end,

  test_non_applying_decisions_never_mint = function()
    local pending_snapshot = snapshot({
      current = { state = nil, version = nil },
      snapshot_fingerprint = "snapshot:pr:7:missing",
    })
    local stale_snapshot = snapshot({
      current = { state = "reviewing", version = V_SAFE_CURRENT },
      snapshot_fingerprint = "snapshot:pr:7:stale",
    })
    local illegal_snapshot = snapshot({ snapshot_fingerprint = "snapshot:pr:7:illegal" })
    local cases = {
      { expected = "pending", snapshot = pending_snapshot, decision = decision(pending_snapshot, "pending") },
      { expected = "stale", snapshot = stale_snapshot, decision = decision(stale_snapshot, "stale") },
      { expected = "illegal", snapshot = illegal_snapshot, decision = decision(illegal_snapshot, "illegal") },
    }
    for _, case in ipairs(cases) do
      t.eq(case.decision.status, case.expected)
      t.eq(restart_effects.mint_grant(case.snapshot, case.decision, AUTHORITATIVE_SINK), nil)
    end
  end,

  test_all_grantless_sink_classes_cannot_mint = function()
    local sealed = snapshot()
    local decided = decision(sealed, "apply")
    local grantless_sink_ids = {
      "adapter:structured-log",
      "queue:github-devloop-decompose.devloop_decompose",
      "comment:pr:review-result-divergence",
    }
    for _, sink_id in ipairs(grantless_sink_ids) do
      t.eq(restart_effects.mint_grant(sealed, decided, sink_id), nil, sink_id)
    end
  end,

  test_grant_is_single_use_and_snapshot_bound = function()
    local sealed = snapshot()
    local decided = decision(sealed, "apply")
    local grant = restart_effects.mint_grant(sealed, decided, AUTHORITATIVE_SINK)
    local other = snapshot({
      entity = { kind = "pr", repo = "owner/repo", number = 8 },
      snapshot_fingerprint = "snapshot:pr:8:v1",
      lock_epoch = "lock:pr:8:epoch:1",
      generation = "generation:1",
    })

    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1], other), false)
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1]), true)
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1]), false)
  end,
}
