local h = require("tests.devloop_helpers")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local execution_start = require("devloop.execution_start")
local restart_effects = require("core.restart_effects")
local restart_effect_facade = require("core.restart_effect_facade")

local t = h.t
local core = h.core
local canonical_json = observation_support.canonical_json

local OWNER = "github-devloop"
local COMMENT_EFFECT_ID = "github-proxy.github_issue_comment_request"
local LABEL_EFFECT_ID = "github-proxy.github_issue_label_request"
local AUTHORITATIVE_SINK = "comment:issue:thinking-state"
local VERSION = "intake/github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function request()
  return execution_start.build_execution_request_payload({
    proposal_id = "github-devloop/issue/owner/repo/42",
    dedup_key = VERSION,
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    origin = {
      package = "github-devloop-intake-default",
      route = "default",
      decision = "enable",
    },
    service_class = "expedite",
  })
end

local function current_issue()
  return {
    repo = "owner/repo",
    number = 42,
    title = "Add retry backoff to failed widget sync",
    body = "Implement exponential backoff for widget sync retries.",
    updated_at = "2026-06-03T01:02:03Z",
    state = "OPEN",
    labels = {},
    comments = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }
end

local function sealed_snapshot()
  return restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "issue", repo = "owner/repo", number = 42 },
    proposal_id = "github-devloop/issue/owner/repo/42",
    current = { state = "thinking", version = VERSION },
    snapshot_fingerprint = "snapshot:issue:42:v1",
    lock_epoch = "lock:issue:42:epoch:7",
    generation = "generation:7",
  })
end

local function real_grant(snapshot)
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "consensus-reached",
    incoming_version = VERSION,
  })
  t.eq(decided.status, "apply")
  return restart_effects.mint_grant(snapshot, decided, AUTHORITATIVE_SINK)
end

local function old_effects()
  local source = request()
  h.mock_context_bundle(source)
  local effects = execution_start.build_execution_start_effects(
    core,
    "owner/repo",
    42,
    source,
    current_issue(),
    "2026-06-03T01:02:04Z",
    "execute_start"
  )
  t.is_true(effects ~= nil)
  return effects
end

local function facade()
  return restart_effect_facade.make({
    verify_grant = restart_effects.verify_grant,
    sink_inventory = require("core.restart.sink_inventory"),
  })
end

local function emit_args(proposal)
  return {
    core = core,
    issue = {
      repo = "owner/repo",
      number = 42,
      source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    },
    proposal = proposal,
  }
end

return {
  test_emit_without_grant_rejects_before_serialization = function()
    local effect, reason = facade().emit(nil, COMMENT_EFFECT_ID, {}, nil)

    t.eq(effect, nil)
    t.eq(reason, "invalid-grant")
  end,

  test_real_grant_emits_comment_and_label_once_each = function()
    local effects = old_effects()
    local snapshot = sealed_snapshot()
    local grant = real_grant(snapshot)
    local shadow = facade()
    local args = emit_args(effects.proposal)

    t.is_true(grant ~= nil)
    t.is_true(shadow.emit(grant, COMMENT_EFFECT_ID, snapshot, args) ~= nil)
    t.eq(shadow.emit(grant, COMMENT_EFFECT_ID, snapshot, args), nil)
    t.is_true(shadow.emit(grant, LABEL_EFFECT_ID, snapshot, args) ~= nil)
    t.eq(shadow.emit(grant, LABEL_EFFECT_ID, snapshot, args), nil)
  end,

  test_shadow_serialization_equals_old_execution_start_writer = function()
    local effects = old_effects()
    local snapshot = sealed_snapshot()
    local grant = real_grant(snapshot)
    local shadow = facade()
    local args = emit_args(effects.proposal)

    local comment = shadow.emit(grant, COMMENT_EFFECT_ID, snapshot, args)
    local label = shadow.emit(grant, LABEL_EFFECT_ID, snapshot, args)

    t.eq(canonical_json(comment), canonical_json(effects.thinking_comment_request))
    t.eq(canonical_json(label), canonical_json(effects.thinking_label_request))
  end,

  test_grantless_published_intent_is_not_accepted = function()
    local snapshot = sealed_snapshot()
    local grant = real_grant(snapshot)
    local effect, reason = facade().emit(
      grant,
      "github-devloop-decompose.devloop_decompose",
      snapshot,
      nil
    )

    t.eq(effect, nil)
    t.eq(reason, "not-lifecycle-authoritative")
  end,
}
