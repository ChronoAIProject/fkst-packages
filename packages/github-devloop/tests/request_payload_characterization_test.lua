local context_bundle = require("devloop.context_bundle")
local entity = require("devloop.entity")
local h = require("tests.devloop_core_helpers")
local markers = require("devloop.markers.builders")
local observation = require("testkit_internal.old_behavior_observation_support")
local operator_commands = require("devloop.operator_commands")
local payloads_board = require("devloop.payloads.board")
local payloads_builders = require("devloop.payloads.builders")
local payloads_predicates = require("devloop.payloads.predicates")
local request_bodies = require("devloop.requests.bodies")
local requests_lifecycle = require("devloop.requests.lifecycle")
local requests_shared = require("devloop.requests.shared")
local sha256 = require("contract.sha256")
local t = h.t
local core = h.core
local dependency_markers = { dependency_gate_note_markers = core.dependency_gate_note_markers, dependency_release_marker = core.dependency_release_marker }
local refusal_inputs = { require_supported_implementation_refusal_reason = core.require_supported_implementation_refusal_reason, implementation_refusal_marker = core.implementation_refusal_marker, ready_split_version = core.ready_split_version, dependency_wait_marker = core.dependency_wait_marker, implement_attempt_marker = core.implement_attempt_marker }

local function slice4_corpus()
  local issue = h.issue()
  local source_ref = h.source_ref()
  local reached = h.reached({
    angle_results = {
      { angle = "teleology", verdict = "approve" },
      { angle = "fidelity", verdict = "approve" },
    },
  })
  local unresolved = h.unresolved({
    narrowed_question = "Which fact remains open?",
    angle_digests = {
      { angle = "teleology", verdict = "comment", digest = "one fact remains" },
    },
  })
  local ready = payloads_builders.build_devloop_ready_payload(reached)
  local version = ready.dedup_key
  local pr_source_ref = entity.pr_source_ref("owner/repo", 7)
  local current_issue = {
    title = "Implement decision recorder",
    updated_at = "2026-06-03T01:02:03Z",
  }
  local merge_ready = {
    proposal_id = reached.proposal_id,
    pr_number = 7,
    version = version,
    reviewed_head_sha = "def456",
  }
  local command = {
    command = "dependency-waiver",
    key = "operator-command-key",
    blocker_number = 9,
  }
  local gate = {
    kind = "satisfied",
    reason = "dependency-void",
    notes = {
      { kind = "dependency-void", blocker_number = 9, reason = "not_planned" },
    },
  }
  local expected = {
    proposal_id = reached.proposal_id,
    state = "ready",
    marker_version = version,
    event_version = version,
  }
  local invalid_hand_off = {
    kind = "own-state-marker",
    proposal_id = reached.proposal_id,
    state = "reviewing",
    marker_version = version,
    event_version = version,
    stage_rank = core.stage_rank("reviewing"),
    comment_id = "IC_slice4",
  }
  local verify_ok, verify_reason = payloads_predicates.verify_own_state_marker_hand_off("owner/repo", invalid_hand_off, expected)
  local verified_state, verified_reason = payloads_predicates.verified_hand_off_state("owner/repo", invalid_hand_off, expected)

  return {
    context_identity = {
      context_bundle.context_bundle_key(reached.proposal_id, version),
      context_bundle.context_bundle_manifest_key(reached.proposal_id, version),
    },
    marker = markers.merged_marker(reached.proposal_id, 7, version, "def456", nil),
    operator_request = operator_commands.build_operator_issue_dependency_waiver_comment_request(core.dependency_waiver_marker, "owner/repo", 42, command, reached.proposal_id, version, 9, source_ref),
    board = {
      block = payloads_board.board_digest_block("owner/repo", nil),
      proposal = payloads_board.append_board_digest_to_proposal({ body = "body" }, "owner/repo", nil),
    },
    payloads = {
      ready = ready,
      board = payloads_builders.build_board_proposal(issue, nil),
      board_loop = payloads_builders.build_board_loop_proposal("owner/repo", 42, current_issue, source_ref, 2, unresolved, nil, "runtime-cache:ctx"),
      review = payloads_builders.build_pr_review_proposal("owner/repo", 42, 7, version, "def456", current_issue, pr_source_ref, {}, "runtime-cache:ctx", true),
      board_review = payloads_builders.build_board_pr_review_proposal("owner/repo", 42, 7, version, "def456", current_issue, pr_source_ref, nil, {}, "runtime-cache:ctx", true),
      review_loop = payloads_builders.build_pr_review_loop_proposal("owner/repo", 42, 7, version, "def456", current_issue, pr_source_ref, 2, unresolved, {}, "runtime-cache:ctx", true),
      board_review_loop = payloads_builders.build_board_pr_review_loop_proposal("owner/repo", 42, 7, version, "def456", current_issue, pr_source_ref, 2, unresolved, nil, {}, "runtime-cache:ctx", true),
    },
    predicates = {
      verify_ok = verify_ok,
      verify_reason = verify_reason,
      verified_state = verified_state or false,
      verified_reason = verified_reason,
    },
    bodies = {
      merging = request_bodies.build_merging_comment_body(core.output_language, merge_ready),
      merged = request_bodies.build_merged_comment_body(core.output_language, merge_ready, nil),
    },
    shared = {
      convergence = requests_shared.build_convergence_display(core.output_language, "Round ", unresolved, 2),
      verdict = requests_shared.build_verdict_summary(core.output_language, reached.angle_results),
    },
    lifecycle = {
      observe = requests_lifecycle.build_observe_comment_request(core.output_language, issue, reached),
      result = requests_lifecycle.build_result_comment_request(core.output_language, "owner/repo", 42, reached),
      converge = requests_lifecycle.build_converge_round_comment_request(core.output_language, "owner/repo", 42, unresolved, 2, "<!-- marker -->"),
      dependency_hold = requests_lifecycle.build_dependency_hold_comment_request(core.output_language, "owner/repo", 42, reached.proposal_id, version,
        { kind = "waiting", hold_kind = "waiting", reason = "waiting-on-dependency" },
        core.dependency_wait_marker(reached.proposal_id, version, { 9 }, "waiting", "waiting-on-dependency"),
        source_ref),
      dependency_release = requests_lifecycle.build_dependency_release_comment_request(
        dependency_markers, core.output_language, "owner/repo", 42, reached.proposal_id, version, gate, source_ref),
      intake = requests_lifecycle.build_intake_decision_comment_request(core.output_language, "owner/repo", 42, {
          proposal_id = reached.proposal_id,
          dedup_key = "intake-dedup",
          source_ref = source_ref,
        }, "enable", "Evidence is sufficient.", "expedite"),
      implementing = requests_lifecycle.build_implementing_comment_request(core.implement_attempt_marker, core.output_language, "owner/repo", 42, ready, "/tmp/worktree", "feature/slice4", "abc123", "dev", "def456", 1, "100", "exec-1"),
      implementing_state = requests_lifecycle.build_implementing_state_comment_request(core.implement_attempt_marker, core.output_language, "owner/repo", 42, ready, "/tmp/worktree", "feature/slice4", "dev", "def456", 1, "100", "exec-1"),
      checkpoint = requests_lifecycle.build_implement_checkpoint_comment_request(core.implement_attempt_marker, core.output_language, "owner/repo", 42, ready, "/tmp/worktree", "feature/slice4", "abc123", "dev", "def456", 1, "100", "exec-1", "Checkpoint detail", "codex-failed"),
      attempt = requests_lifecycle.build_implement_attempt_comment_request(core.implement_attempt_marker, "owner/repo", 42, ready, 1, "100", "exec-1"),
      mismatch = requests_lifecycle.build_implement_version_mismatch_comment_request(core.implement_version_mismatch_marker, "owner/repo", 42, ready, version, version .. "/new", 1),
      failure = requests_lifecycle.build_impl_failure_comment_request(core.impl_failure_marker, core.output_language, "owner/repo", 42, ready, "no-changes", "No changed files.", 1, "UNKNOWN", false),
      refusal = requests_lifecycle.build_implementation_refusal_comment_request(
        refusal_inputs, "owner/repo", 42, ready, "wrong-layer", "The change belongs in substrate.", 1, "100", "exec-1"),
      merging = requests_lifecycle.build_merging_comment_request(core.output_language, "owner/repo", merge_ready),
    },
  }
end

return {
  test_slice4_issue_request_and_payload_bytes_are_frozen = function()
    local bytes = observation.canonical_json(slice4_corpus())
    t.eq(sha256.hex(bytes), "1ecdbd4c8bbbcb8eacdf1f834bb899ef7ae6361a6d275eab98fdbc6fef52104c")
  end,
}
