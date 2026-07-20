local h = require("tests.devloop_helpers")
local entity_lib = require("devloop.entity")
local requests_labels = require("devloop.requests.labels")
local requests_review = require("devloop.requests.review")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local restart_effects = require("core.restart_effects")
local restart_effect_facade = require("core.restart_effect_facade")

local t = h.t
local core = h.core
local canonical_json = observation_support.canonical_json

local OWNER = "github-devloop-pr"
local ISSUE_PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local VERSION = "2026-06-03T01-02-03Z"
local REVIEW_PROPOSAL_ID = "github-devloop/pr-review/owner-repo-2718475964/7/" .. VERSION .. "/def456"
local COMMENT_EFFECT_ID = "github-proxy.github_pr_comment_request"
local LABEL_EFFECT_ID = "github-proxy.github_issue_label_request"
local AUTHORITATIVE_SINK = "comment:pr:review-result"
local FIX_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local FIXED_HEAD = "feedface"

local function reached()
  return h.review_reached({
    proposal_id = REVIEW_PROPOSAL_ID,
    dedup_key = "consensus:" .. REVIEW_PROPOSAL_ID .. "/review",
    decision = "reject",
    body = "Review consensus rejects the diff.",
    blocking_gap = "missing facade parity guard",
  })
end

local function sealed_snapshot()
  return restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "pr", repo = "owner/repo", number = 7 },
    proposal_id = ISSUE_PROPOSAL_ID,
    current = { state = "reviewing", version = VERSION },
    snapshot_fingerprint = "snapshot:pr:7:v1",
    lock_epoch = "lock:pr:7:epoch:7",
    generation = "generation:7",
  })
end

local function real_grant(snapshot)
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "changes_requested",
    target = "fixing",
    incoming_version = VERSION,
    overlay_version = VERSION,
  })
  t.eq(decided.status, "apply")
  return restart_effects.mint_grant(snapshot, decided, AUTHORITATIVE_SINK)
end

local function emit_args(review)
  return {
    core = core,
    repo = "owner/repo",
    issue_number = "42",
    issue_proposal_id = ISSUE_PROPOSAL_ID,
    issue_version = core.next_fix_version(VERSION),
    reached = review,
    pr_source_ref = entity_lib.pr_source_ref("owner/repo", 7),
    issue_source_ref = entity_lib.issue_source_ref("owner/repo", 42),
    marker_target = { kind = "pr", number = 7 },
  }
end

local function facade(family)
  return restart_effect_facade.make({
    family = family or "pr-review-result",
    verify_grant = restart_effects.verify_grant,
    sink_inventory = require("core.restart.sink_inventory"),
  })
end

local function fix_snapshot()
  return restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "pr", repo = "owner/repo", number = 7 },
    proposal_id = ISSUE_PROPOSAL_ID,
    current = { state = "fixing", version = FIX_VERSION },
    snapshot_fingerprint = "snapshot:pr:7:fix:v1",
    lock_epoch = "lock:pr:7:fix:epoch:7",
    generation = "generation:fix:7",
  })
end

local function fix_grant(snapshot)
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "revision_published",
    target = "reviewing",
    incoming_version = FIX_VERSION,
    target_version = core.next_fix_version(FIX_VERSION),
    overlay_version = FIX_VERSION,
  })
  t.eq(decided.status, "apply")
  return restart_effects.mint_grant(snapshot, decided, "comment:pr:fix-reviewing")
end

local function fix_args()
  local fix = h.fixing()
  fix.version = FIX_VERSION
  fix.source_ref = entity_lib.pr_source_ref("owner/repo", 7)
  return {
    core = core,
    repo = "owner/repo",
    issue_number = "42",
    fix = fix,
    old_head_sha = fix.reviewed_head_sha,
    new_head_sha = FIXED_HEAD,
    new_version = core.next_fix_version(FIX_VERSION),
  }
end

return {
  test_emit_without_grant_rejects_before_serialization = function()
    local effect, reason = facade().emit(nil, COMMENT_EFFECT_ID, {}, nil)
    t.eq(effect, nil)
    t.eq(reason, "invalid-grant")
  end,

  test_real_grant_emits_comment_and_label_once_each = function()
    h.mock_default_issue_claim()
    local snapshot = sealed_snapshot()
    local grant = real_grant(snapshot)
    local args = emit_args(reached())
    local shadow = facade()

    t.is_true(grant ~= nil)
    t.is_true(shadow.emit(grant, COMMENT_EFFECT_ID, snapshot, args) ~= nil)
    t.eq(shadow.emit(grant, COMMENT_EFFECT_ID, snapshot, args), nil)
    t.is_true(shadow.emit(grant, LABEL_EFFECT_ID, snapshot, args) ~= nil)
    t.eq(shadow.emit(grant, LABEL_EFFECT_ID, snapshot, args), nil)
  end,

  test_shadow_serialization_equals_old_review_result_writer = function()
    h.mock_default_issue_claim()
    local review = reached()
    local args = emit_args(review)
    local snapshot = sealed_snapshot()
    local grant = real_grant(snapshot)
    local shadow = facade()
    local comment = shadow.emit(grant, COMMENT_EFFECT_ID, snapshot, args)
    local label = shadow.emit(grant, LABEL_EFFECT_ID, snapshot, args)
    local old_comment = requests_review.build_review_result_comment_request(
      core, args.repo, args.issue_number, args.issue_proposal_id,
      args.issue_version, review, args.pr_source_ref
    )
    local old_label = requests_labels.build_review_result_label_request(
      args.repo, args.issue_number, args.issue_proposal_id, args.issue_version,
      review, args.issue_source_ref, args.marker_target
    )

    t.eq(canonical_json(comment), canonical_json(old_comment))
    t.eq(canonical_json(label), canonical_json(old_label))
  end,

  test_fix_shadow_serialization_equals_old_fix_writer = function()
    h.mock_default_issue_claim()
    local snapshot = fix_snapshot()
    local grant = fix_grant(snapshot)
    local args = fix_args()
    local shadow = facade("pr-fix")
    local comment = shadow.emit(grant, COMMENT_EFFECT_ID, snapshot, args)
    local label = shadow.emit(grant, LABEL_EFFECT_ID, snapshot, args)
    local old_comment = requests_review.build_fix_reviewing_comment_request(
      core, args.repo, args.issue_number, args.fix, args.old_head_sha,
      args.new_head_sha, args.new_version
    )
    local old_label = requests_labels.build_fix_reviewing_label_request(
      args.repo, args.issue_number, args.fix, args.new_head_sha, args.new_version
    )

    t.eq(canonical_json(comment), canonical_json(old_comment))
    t.eq(canonical_json(label), canonical_json(old_label))
  end,

  test_grantless_non_lifecycle_effect_is_not_accepted = function()
    local snapshot = sealed_snapshot()
    local effect, reason = facade().emit(
      real_grant(snapshot), "github-devloop-decompose.devloop_decompose", snapshot, nil
    )

    t.eq(effect, nil)
    t.eq(reason, "not-lifecycle-authoritative")
  end,
}
