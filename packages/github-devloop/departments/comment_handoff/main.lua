local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local core = require("core")
local saga = require("workflow.saga")
local source_refs = require("contract.source_ref")
local valid_round = require("devloop.rounds").valid_round
local handoff_helpers = require("devloop.comment_handoff")
local requests_labels = require("devloop.requests.labels")

local payloads_builders = require("devloop.payloads.builders")
local payloads_predicates = require("devloop.payloads.predicates")
local conv_reconcile = require("devloop.convergence.reconcile")
local conv_rounds = require("devloop.convergence.rounds")
local devloop_logging = require("devloop.logging")
local spec = {
  consumes = { "github-proxy.github_comment_written" },
  produces = {
    "github-proxy.github_issue_label_request",
    "devloop_ready",
    "devloop_reconcile",
  },
  fanout = { "github-proxy.github_comment_written" },
  stall_window = "30s",
}

local function same_value(left, right)
  return tostring(left or "") == tostring(right or "")
end

local function projected_state_label_request(payload, handoff, expected_state)
  local request = handoff.label_request
  local guard = type(request) == "table" and request.marker_guard or nil
  local guard_expected = type(guard) == "table" and guard.expected or nil
  local guard_match = type(guard) == "table" and guard.match or nil
  local guard_target = type(guard) == "table" and guard.marker_target or nil
  if type(request) ~= "table"
    or request.schema ~= "github-proxy.label.v1"
    or request.target_kind ~= "issue"
    or request.require_marker_guard ~= true
    or not strings.is_bounded_string(request.dedup_key, devloop_base._max_dedup_len)
    or not source_refs.has_bounded_source_ref(request.source_ref, devloop_base._max_key_len)
    or not same_value(request.repo, payload.repo)
    or not same_value(request.issue_number, payload.issue_number)
    or not same_value(request.target_number, payload.issue_number)
    or not same_value(request.expected_proposal_id, handoff.proposal_id)
    or not same_value(request.expected_state, expected_state)
    or not same_value(request.expected_version, handoff.marker_version)
    or not requests_labels.is_canonical_state_marker_guard(guard)
    or type(guard_expected) ~= "table"
    or type(guard_match) ~= "table"
    or type(guard_target) ~= "table"
    or not same_value(guard_expected.state, expected_state)
    or not same_value(guard_expected.version, handoff.marker_version)
    or not same_value(guard_match.proposal, handoff.proposal_id)
    or not same_value(guard_target.kind, "issue")
    or not same_value(guard_target.number, payload.issue_number) then
    return nil
  end
  return request
end

local function supported_handoff(payload)
  if type(payload) ~= "table"
    or payload.schema ~= "github-proxy.comment-written.v1"
    or not payloads_predicates.is_safe_comment_id(payload.comment_id)
    or type(payload.handoff) ~= "table" then
    return nil
  end
  local handoff = payload.handoff
  if handoff.kind == "github-devloop.ready"
    and devloop_base.is_safe_consensus_result_ref(handoff.proposal_id, handoff.version)
    and devloop_base.is_safe_consensus_result_ref(handoff.proposal_id, handoff.marker_version)
    and strings.is_bounded_string(handoff.version, devloop_base._max_dedup_len)
    and (handoff.framing == nil
      or strings.is_bounded_string(handoff.framing, devloop_base._max_framing_len))
    and source_refs.has_bounded_source_ref(handoff.source_ref, devloop_base._max_key_len) then
    if projected_state_label_request(payload, handoff, "ready") ~= nil then
      return handoff
    end
    return nil
  end
  if handoff.kind == "github-devloop.ready-split-label"
    and devloop_base.is_safe_consensus_result_ref(handoff.proposal_id, handoff.version)
    and devloop_base.is_safe_consensus_result_ref(handoff.proposal_id, handoff.marker_version)
    and strings.is_bounded_string(handoff.version, devloop_base._max_dedup_len)
    and source_refs.has_bounded_source_ref(handoff.source_ref, devloop_base._max_key_len)
    and projected_state_label_request(payload, handoff, "dependency_wait") ~= nil then
    return handoff
  end
  if handoff.kind == "github-devloop.declined-label"
    and devloop_base.is_safe_consensus_result_ref(handoff.proposal_id, handoff.version)
    and devloop_base.is_safe_consensus_result_ref(handoff.proposal_id, handoff.marker_version)
    and strings.is_bounded_string(handoff.version, devloop_base._max_dedup_len)
    and source_refs.has_bounded_source_ref(handoff.source_ref, devloop_base._max_key_len)
    and projected_state_label_request(payload, handoff, "declined") ~= nil then
    return handoff
  end
  if handoff.kind == "github-devloop.reconcile"
    and devloop_base.is_safe_consensus_result_ref(handoff.proposal_id, handoff.base_version)
    and strings.is_bounded_string(handoff.base_version, devloop_base._max_dedup_len)
    and conv_rounds.is_terminal_cause(handoff.terminal_cause)
    and valid_round(handoff.round) ~= nil
    and source_refs.has_bounded_source_ref(handoff.source_ref, devloop_base._max_key_len) then
    return handoff
  end
  return nil
end

local accept_handoff = handoff_helpers.acceptor(supported_handoff)

local function handoff_done(_event)
  return false
end

local log_unsupported_handoff = function(event) return handoff_helpers.log_unsupported(supported_handoff, event) end

local function act_handoff(event)
  local payload = event.payload or {}
  local handoff = supported_handoff(payload)
  if handoff == nil then
    log_unsupported_handoff(event)
    return
  end

  devloop_logging.log_entry("comment_handoff", event, handoff.proposal_id, payload.dedup_key)
  if handoff.kind == "github-devloop.ready" then
    devloop_logging.log_raise("comment_handoff", handoff.proposal_id,
      "github-proxy.github_issue_label_request", handoff.label_request)
    local ready = payloads_builders.build_devloop_ready_payload({
      proposal_id = handoff.proposal_id,
      dedup_key = handoff.marker_version,
      source_ref = handoff.source_ref,
      include_ready_hand_off = true,
      ready_comment_id = payload.comment_id,
      framing = handoff.framing,
    })
    devloop_logging.log_cas_decision("comment_handoff", handoff.proposal_id, { state = "ready", version = ready.dedup_key }, "comment-written", "devloop_ready", "applied(own-write-comment-id)", "ready marker comment write was acknowledged")
    devloop_logging.log_raise("comment_handoff", handoff.proposal_id, "devloop_ready", ready)
    return
  end

  if handoff.kind == "github-devloop.ready-split-label" then
    devloop_logging.log_cas_decision("comment_handoff", handoff.proposal_id,
      { state = "dependency_wait", version = handoff.marker_version },
      "comment-written", "github-proxy.github_issue_label_request",
      "applied(own-write-comment-id)", "ready split marker comment write was acknowledged")
    devloop_logging.log_raise("comment_handoff", handoff.proposal_id,
      "github-proxy.github_issue_label_request", handoff.label_request)
    return
  end

  if handoff.kind == "github-devloop.declined-label" then
    devloop_logging.log_cas_decision("comment_handoff", handoff.proposal_id,
      { state = "declined", version = handoff.marker_version },
      "comment-written", "github-proxy.github_issue_label_request",
      "applied(own-write-comment-id)", "declined marker comment write was acknowledged")
    devloop_logging.log_raise("comment_handoff", handoff.proposal_id,
      "github-proxy.github_issue_label_request", handoff.label_request)
    return
  end

  if handoff.kind == "github-devloop.reconcile" then
    local reconcile = conv_reconcile.build_devloop_reconcile_payload({
      proposal_id = handoff.proposal_id,
      source_ref = handoff.source_ref,
    }, handoff.round, handoff.base_version, handoff.terminal_cause)
    devloop_logging.log_cas_decision("comment_handoff", handoff.proposal_id, { state = "thinking", version = handoff.base_version }, "comment-written", "devloop_reconcile", "applied(own-write-comment-id)", "converge round comment write was acknowledged")
    devloop_logging.log_raise("comment_handoff", handoff.proposal_id, "devloop_reconcile", reconcile)
    return
  end

  log_unsupported_handoff(event)
end

return saga.department(spec, {
  accept = accept_handoff,
  done = handoff_done,
  act = act_handoff,
  on_skip_foreign = log_unsupported_handoff,
  wrap = devloop_logging.wrap_pipeline_failure,
  name = "comment_handoff",
})
