local F = {}

local function make(deps)
local contract_time = deps.contract_time
local conv_reconcile = deps.conv_reconcile
local core = deps.core
local dependency_hold_fact = deps.dependency_hold_fact
local devloop_logging = deps.devloop_logging
local devloop_state = deps.devloop_state
local operator_commands = deps.operator_commands
local replayer = deps.replayer
local replay_fields = deps.replay_fields
local restart_transition_table = deps.restart_policy.restart_transition_table
local M = {}

local function thinking_state_budget_exceeded(state)
  local threshold = core.stall_suspect_threshold_minutes("thinking")
  local marker_seconds = contract_time.iso_timestamp_epoch_seconds(state and state.marker_created_at)
  if threshold == nil or marker_seconds == nil then
    return false
  end
  return now() - marker_seconds >= threshold * 60
end

local function maybe_apply_issue_rereview_command(issue, proposal_id, current, state, event_ts)
  local command = operator_commands.operator_command_fact(current.comments, "rereview")
  if command == nil then
    return false
  end
  if operator_commands.has_operator_command_response(current.comments, command) then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "stalled-thinking", "thinking", "skip-idempotent(command-response-visible)", "operator command response marker is already visible")
    return false
  end
  if state.state ~= "thinking" then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "thinking", "thinking", "refused(invalid-state)", "operator rereview requires thinking")
    local refusal = operator_commands.build_operator_issue_command_refusal_request(issue.repo,
      issue.number,
      command,
      "rereview requires thinking state",
      issue.source_ref
    )
    devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", refusal)
    return true
  end
  if not replayer.has_thinking_converge_replay(core, current, proposal_id, state, issue.source_ref)
    and not thinking_state_budget_exceeded(state) then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "stalled-thinking", "thinking", "refused(active-thinking)", "operator rereview requires stalled thinking")
    local refusal = operator_commands.build_operator_issue_command_refusal_request(issue.repo,
      issue.number,
      command,
      "rereview requires stalled thinking state",
      issue.source_ref
    )
    devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", refusal)
    return true
  end

  local proposal = replayer.build_thinking_replay_proposal(core, issue, proposal_id, state, current, event_ts)
  if proposal == nil then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "stalled-thinking", "thinking", "refused(cannot-rebuild-proposal)", "operator rereview could not rebuild thinking proposal")
    local refusal = operator_commands.build_operator_issue_command_refusal_request(issue.repo,
      issue.number,
      command,
      "rereview could not rebuild the current thinking proposal",
      issue.source_ref
    )
    devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", refusal)
    return true
  end

  local comment_request = operator_commands.build_operator_issue_rereview_comment_request(issue.repo,
    issue.number,
    command,
    proposal,
    issue.source_ref
  )
  devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "stalled-thinking", "thinking", "applied(operator-rereview)", "trusted operator command requested issue rereview")
  devloop_logging.log_apply("observe_issue", proposal_id, "thinking", proposal.dedup_key, { add = {}, remove = {} }, {
    "github-proxy.github_issue_comment_request",
    "devloop_consensus_request",
  })
  devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", comment_request)
  devloop_logging.log_raise("observe_issue", proposal_id, "devloop_consensus_request", proposal)
  return true
end

local function timeout_reconcile_reready_reentry_state(current, proposal_id, state, source_ref, link)
  if state.state ~= "blocked" or link ~= nil then
    return nil, "reready requires ready or dependency_wait state"
  end
  local fact = conv_reconcile.timeout_reconcile_fact_for_terminal_version_from_states(current.comments, proposal_id, state.version, {
    ready = true,
    dependency_wait = true,
  })
  if fact == nil then
    return nil, "reready requires ready or dependency_wait state"
  end
  if fact.from_state ~= "ready" and fact.from_state ~= "dependency_wait" then
    return nil, "reready requires timeout-reconcile from ready or dependency_wait state"
  end
  local marker_source = fact.source_ref or {}
  if tostring(marker_source.kind or "") ~= tostring(source_ref and source_ref.kind or "")
    or tostring(marker_source.ref or "") ~= tostring(source_ref and source_ref.ref or "") then
    return nil, "reready requires timeout-reconcile source_ref to match the issue"
  end
  return {
    state = fact.from_state,
    version = fact.from_version,
    stage_rank = devloop_state.stage_rank(fact.from_state),
    marker_created_at = fact.comment_created_at,
    operator_reentry = {
      command = "reready",
      from_state = "blocked",
      terminal_version = state.version,
      timeout_round = fact.round,
    },
  }, nil
end

local function dependency_hold_reready_reentry_state(current, proposal_id, state, link)
  if state.state ~= "blocked" or link ~= nil then
    return nil
  end
  local fact = dependency_hold_fact(current.comments, proposal_id)
  if fact == nil or tostring(fact.version or "") ~= tostring(state.version or "") then
    return nil
  end
  return {
    state = "dependency_wait",
    version = state.version,
    stage_rank = devloop_state.stage_rank("dependency_wait"),
    marker_created_at = fact.comment_created_at,
    operator_reentry = {
      command = "reready",
      from_state = "blocked",
      boundary = "dependency-hold",
      terminal_version = state.version,
      dependency_origin = {
        marker_kind = fact.marker_kind,
        version = fact.version,
      },
    },
  }
end

local function maybe_apply_issue_reready_command(issue, proposal_id, current, state, link)
  local command = operator_commands.operator_command_fact(current.comments, "reready")
  if command == nil then
    return false
  end
  if operator_commands.has_operator_command_response(current.comments, command) then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "ready", "ready", "skip-idempotent(command-response-visible)", "operator command response marker is already visible")
    return false
  end
  local replay_state = state
  local refusal_reason = nil
  if state.state ~= "ready" and state.state ~= "dependency_wait" then
    replay_state = dependency_hold_reready_reentry_state(current, proposal_id, state, link)
    if replay_state == nil then
      replay_state, refusal_reason = timeout_reconcile_reready_reentry_state(
        current, proposal_id, state, issue.source_ref, link)
    end
  end
  if replay_state == nil then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "ready", "ready", "refused(invalid-state)", "operator reready requires ready state")
    local refusal = operator_commands.build_operator_issue_command_refusal_request(issue.repo,
      issue.number,
      command,
      refusal_reason or "reready requires ready or dependency_wait state",
      issue.source_ref
    )
    devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", refusal)
    return true
  end
  local row, replay_facts = core.replay_row_and_facts_with_declared_dependency_gate(
    issue, proposal_id, replay_state,
    current, command
  )
  replayer.replay_from_table(core, "observe_issue", issue, replay_state, row, replay_facts)
  return true
end

local function has_unmet_blocker(gate, blocker_number)
  if type(gate) ~= "table" or type(gate.unmet) ~= "table" then
    return false
  end
  for _, number in ipairs(gate.unmet) do
    if tonumber(number) == tonumber(blocker_number) then
      return true
    end
  end
  return false
end

local function maybe_apply_issue_dependency_waiver_command(issue, proposal_id, current, state)
  local command = operator_commands.operator_command_fact(current.comments, "dependency-waiver")
  if command == nil then
    return false
  end
  if operator_commands.has_operator_command_response(current.comments, command) then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "ready", "ready", "skip-idempotent(command-response-visible)", "operator command response marker is already visible")
    return false
  end
  if state.state ~= "dependency_wait" then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "dependency_wait", "ready", "refused(invalid-state)", "operator dependency waiver requires dependency_wait state")
    local refusal = operator_commands.build_operator_issue_command_refusal_request(issue.repo,
      issue.number,
      command,
      "dependency-waiver requires dependency_wait state",
      issue.source_ref
    )
    devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", refusal)
    return true
  end

  local blocker_number = command.blocker_number
  local gate = core.dependency_gate(issue.repo, issue.number, {
    proposal_id = proposal_id,
    version = state.version,
    comments = current.comments,
  })
  if gate.kind ~= "waiting"
    or gate.reason ~= "dependency-waiver-required"
    or not has_unmet_blocker(gate, blocker_number) then
    devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "ready", "ready", "refused(invalid-dependency-waiver)", "operator dependency waiver requires a matching completed blocker without merged marker")
    local refusal = operator_commands.build_operator_issue_command_refusal_request(issue.repo,
      issue.number,
      command,
      "dependency-waiver requires a matching completed blocker without merged marker",
      issue.source_ref
    )
    devloop_logging.log_raise("observe_issue", proposal_id, "github-proxy.github_issue_comment_request", refusal)
    return true
  end

  local comment_request = operator_commands.build_operator_issue_dependency_waiver_comment_request(
    core,
    issue.repo,
    issue.number,
    command,
    proposal_id,
    state.version,
    blocker_number,
    issue.source_ref
  )
  devloop_logging.log_cas_decision("observe_issue", proposal_id, state, "dependency_wait", "ready", "applied(operator-dependency-waiver)", "trusted operator command created dependency waiver")
  replayer.replay_from_table(core, "observe_issue", issue, state, replay_fields.restart_transition_row(restart_transition_table(), "dependency_wait"), {
    proposal_id = proposal_id,
    current = current,
    command_comment_request = comment_request,
    dependency_gate = {
      kind = "satisfied",
      reason = "dependency-waiver",
      notes = {
        {
          kind = "dependency-waiver",
          blocker_number = blocker_number,
          reason = "completed_without_merged_marker",
        },
      },
      unmet = {},
    },
  })
  return true
end

M.maybe_apply_issue_rereview_command = maybe_apply_issue_rereview_command
M.maybe_apply_issue_reready_command = maybe_apply_issue_reready_command
M.maybe_apply_issue_dependency_waiver_command = maybe_apply_issue_dependency_waiver_command

return M
end

F.make = make

return F
