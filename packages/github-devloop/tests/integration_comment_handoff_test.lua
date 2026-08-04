local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local implementation_escalation = require("devloop.implementation_escalation")
local payloads_builders = require("devloop.payloads.builders")
local v_ready = require("devloop.validators.ready")
local t = h.t
local core = h.core
local opts = h.opts
local find_raise = h.find_raise

local function run_handoff(payload, name)
  return t.run_department("departments/comment_handoff/main.lua", {
    queue = "github-proxy.github_comment_written",
    payload = payload,
  }, opts(name))
end

return {
  test_comment_written_ready_ack_raises_durable_ready_with_verifiable_hand_off = function()
    local source_ref = entity_lib.issue_source_ref("owner/repo", 42)
    local version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local result = run_handoff({
      schema = "github-proxy.comment-written.v1",
      repo = "owner/repo",
      target = "issue",
      issue_number = 42,
      comment_id = "IC_ready_1",
      request_dedup_key = "github-devloop/issue/owner/repo/42/comment/approve/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
      dedup_key = "github-devloop/issue/owner/repo/42/comment/approve/written/IC_ready_1",
      source_ref = source_ref,
      handoff = {
        kind = "github-devloop.ready",
        proposal_id = "github-devloop/issue/owner/repo/42",
        version = version,
        marker_version = version,
        source_ref = source_ref,
      },
    }, "comment-handoff-ready")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local ready = find_raise(result.raises, "devloop_ready").payload
    t.eq(ready.schema, "github-devloop.ready.v1")
    t.eq(ready.ready_hand_off.comment_id, "IC_ready_1")
    t.eq(ready.ready_hand_off.marker_version, version)
    t.eq(ready.ready_hand_off.event_version, ready.dedup_key)
    t.eq(v_ready.is_supported_ready(core, ready), true)
  end,

  test_comment_written_ready_ack_preserves_effect_version_marker_identity = function()
    local source_ref = entity_lib.issue_source_ref("owner/repo", 42)
    local event_version = "consensus:github-devloop/issue/owner/repo/42/intake/1234567890"
    local marker_version = "intake/github-devloop/issue/owner/repo/42/2026-06-03T02-02-03Z"
    local result = run_handoff({
      schema = "github-proxy.comment-written.v1",
      repo = "owner/repo",
      target = "issue",
      issue_number = 42,
      comment_id = "IC_ready_effect_1",
      request_dedup_key = "github-devloop/issue/owner/repo/42/comment/approve/consensus-github-devloop/issue/owner/repo/42/intake/1234567890",
      dedup_key = "github-devloop/issue/owner/repo/42/comment/approve/written/IC_ready_effect_1",
      source_ref = source_ref,
      handoff = {
        kind = "github-devloop.ready",
        proposal_id = "github-devloop/issue/owner/repo/42",
        version = event_version,
        marker_version = marker_version,
        source_ref = source_ref,
      },
    }, "comment-handoff-ready-effect-version")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local ready = find_raise(result.raises, "devloop_ready").payload
    t.eq(ready.dedup_key, payloads_builders.build_devloop_ready_payload(core, {
      proposal_id = "github-devloop/issue/owner/repo/42",
      dedup_key = marker_version,
      source_ref = source_ref,
    }).dedup_key)
    t.is_true(ready.dedup_key ~= payloads_builders.build_devloop_ready_payload(core, {
      proposal_id = "github-devloop/issue/owner/repo/42",
      dedup_key = event_version,
      source_ref = source_ref,
    }).dedup_key)
    t.eq(ready.ready_hand_off.comment_id, "IC_ready_effect_1")
    t.eq(ready.ready_hand_off.marker_version, marker_version)
    t.eq(ready.ready_hand_off.event_version, ready.dedup_key)
    t.eq(v_ready.is_supported_ready(core, ready), true)
  end,

  test_comment_written_implementation_escalation_ack_raises_pre_pr_supervisor_seam = function()
    local source_ref = entity_lib.issue_source_ref("owner/repo", 42)
    local version = "ready/github-devloop/issue/owner/repo/42/intake/123"
    local handoff = implementation_escalation.build_payload({
      proposal_id = "github-devloop/issue/owner/repo/42",
      version = version,
      branch = "devloop-owner-repo-42-123",
      source_ref = source_ref,
    }, {
      policy_id = "adjacent-wall-clock-exhaustion-stationary-head-v1",
      previous_attempt = 1,
      attempt = 2,
      head_sha = "1111111111111111111111111111111111111111",
    })
    handoff.kind = "github-devloop.implementation-escalation"
    local result = run_handoff({
      schema = "github-proxy.comment-written.v1",
      repo = "owner/repo",
      target = "issue",
      issue_number = 42,
      comment_id = "IC_implementation_escalation_1",
      request_dedup_key = "implement/comment/checkpoint/2",
      dedup_key = "implement/comment/checkpoint/2/written/IC_implementation_escalation_1",
      source_ref = source_ref,
      handoff = handoff,
    }, "comment-handoff-implementation-escalation")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local raised = find_raise(result.raises, "github-devloop-decompose.devloop_decompose")
    t.eq(raised.payload.schema, "github-devloop.implementation-escalation.v1")
    t.eq(raised.payload.attempt, 2)
    t.eq(raised.payload.head_sha, "1111111111111111111111111111111111111111")
  end,

}
