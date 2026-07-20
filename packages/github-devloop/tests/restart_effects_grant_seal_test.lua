local h = require("tests.devloop_core_helpers")
local restart_authority = require("core.restart_authority")
local restart_effects = require("core.restart_effects")

local t = h.t

local OWNER = "github-devloop"
local EDGE_ID = "github-devloop/thinking/autonomous/consensus-reached"
local APPLY_ENTITLEMENT_ID = EDGE_ID .. "/apply"
local IDEMPOTENT_ENTITLEMENT_ID = EDGE_ID .. "/idempotent"
local EFFECT_IDS = {
  "github-proxy.github_issue_comment_request",
  "github-proxy.github_issue_label_request",
}
local AUTHORITATIVE_SINK = "comment:issue:consensus-result"
local V_CURRENT = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_OLDER = "consensus:github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_NEWER = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"

local function snapshot(overrides)
  local fields = {
    owner = OWNER,
    entity = { kind = "issue", repo = "owner/repo", number = 42 },
    proposal_id = "github-devloop/issue/owner/repo/42",
    current = { state = "thinking", version = V_CURRENT },
    snapshot_fingerprint = "snapshot:issue:42:v1",
    lock_epoch = "lock:issue:42:epoch:7",
    generation = "generation:7",
  }
  for key, value in pairs(overrides or {}) do
    fields[key] = value
  end
  return restart_effects.seal_snapshot(fields)
end

local function decision(sealed_snapshot, status)
  local intent = { semantic_variant = "consensus-reached", incoming_version = V_CURRENT }
  if status == "pending" then
    intent.incoming_version = V_NEWER
  elseif status == "stale" then
    intent.incoming_version = V_OLDER
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

    local analysis_snapshot = snapshot({ snapshot_fingerprint = "snapshot:issue:42:analysis" })
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
    t.eq(decided.effect_entitlement_id, APPLY_ENTITLEMENT_ID)
    assert_array(decided.granted_effect_ids, EFFECT_IDS, "apply entitlement")

    local grant = restart_effects.mint_grant(sealed, decided, AUTHORITATIVE_SINK)
    t.eq(type(grant), "table")
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1]), true)
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[2]), true)
    t.eq(restart_effects.verify_grant(grant, "github-devloop.devloop_ready"), false)
  end,

  test_idempotent_grant_uses_only_the_exact_idempotent_entitlement = function()
    local sealed = snapshot({
      current = { state = "ready", version = V_CURRENT },
      snapshot_fingerprint = "snapshot:issue:42:ready:v1",
    })
    local decided = decision(sealed, "idempotent")
    t.eq(decided.status, "idempotent")
    t.eq(decided.effect_entitlement_id, IDEMPOTENT_ENTITLEMENT_ID)
    assert_array(decided.granted_effect_ids, EFFECT_IDS, "idempotent entitlement")

    local grant = restart_effects.mint_grant(sealed, decided, AUTHORITATIVE_SINK)
    t.eq(type(grant), "table")
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1]), true)
    t.eq(restart_effects.verify_grant(grant, "github-devloop.devloop_ready"), false)
  end,

  test_non_applying_decisions_never_mint = function()
    local pending_snapshot = snapshot({
      current = { state = nil, version = nil },
      snapshot_fingerprint = "snapshot:issue:42:missing",
    })
    local stale_snapshot = snapshot({ snapshot_fingerprint = "snapshot:issue:42:stale" })
    local illegal_snapshot = snapshot({ snapshot_fingerprint = "snapshot:issue:42:illegal" })
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
      "adapter:github.pr-create",
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
      entity = { kind = "issue", repo = "owner/repo", number = 43 },
      proposal_id = "github-devloop/issue/owner/repo/43",
      snapshot_fingerprint = "snapshot:issue:43:v1",
      lock_epoch = "lock:issue:43:epoch:1",
      generation = "generation:1",
    })

    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1], other), false)
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1]), true)
    t.eq(restart_effects.verify_grant(grant, EFFECT_IDS[1]), false)
  end,
}
