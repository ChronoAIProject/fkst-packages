local entity_lib = require("devloop.entity")
local base_ids = require("devloop.base_ids")
local dependency_gate = require("devloop.dependency_gate")
local m_claims = require("devloop.claims")
local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")
local payloads_builders = require("devloop.payloads.builders")
local conv_attempts = require("devloop.convergence.attempts")
local marker_shared = require("devloop.markers.shared")
local devloop_state = require("devloop.state")
local S = {}
local operator_commands = require("devloop.operator_commands")
local replay_fields_resolver = require("devloop.replay_fields")
local comment_strings = require("devloop.strings")
local devloop_logging = require("devloop.logging")

function S.install(M)

local dependency_gate_rederive = true

local function ready_split_canonicalized_marker(proposal_id, from_version, to_version, derived_state, reason)
  return '<!-- fkst:github-devloop:ready-split-canonicalized:v1 proposal="' .. tostring(proposal_id)
    .. '" from_version="' .. marker_shared.safe_marker_attr(from_version)
    .. '" to_version="' .. marker_shared.safe_marker_attr(to_version)
    .. '" derived_state="' .. marker_shared.safe_marker_attr(derived_state)
    .. '" reason="' .. marker_shared.safe_marker_attr(reason or "ready_split_rederive")
    .. '" -->'
end

function M.raise_ready_split_effects(dept, issue, proposal_id, from_version, to_state, to_version, gate, label_dedup_key, additional_raised)
  if to_state ~= "ready" and to_state ~= "dependency_wait" then
    error("github-devloop: ready-split-target-invalid: target must be ready or dependency_wait")
  end
  local add_labels = {}
  local remove_labels = {}
  if to_state == "dependency_wait" then
    table.insert(add_labels, M._blocked_on_dependency_label)
  else
    table.insert(remove_labels, M._blocked_on_dependency_label)
  end
  local state_effects = to_state == "ready"
    and "result-marker,ready-label,devloop-ready"
    or "ready-split-canonicalized"
  local body_after_marker = ""
  if to_state == "dependency_wait" then
    body_after_marker = "\n" .. M.dependency_wait_marker(
      proposal_id,
      to_version,
      gate and gate.unmet or {},
      gate and gate.hold_kind or "waiting",
      gate and gate.reason or "waiting-on-dependency"
    )
  end
  local comment_request = devloop_state.build_projected_state_comment_request({
    repo = issue.repo,
    issue_number = issue.number,
    proposal_id = proposal_id,
    state = to_state,
    marker_version = to_version,
    handoff_version = to_version,
    effects = state_effects,
    body_before_marker = "github-devloop ready split canonicalized"
      .. "\n\n" .. comment_strings.comment_string(M, "reason_inline_label") .. tostring(gate and gate.reason or "ready_split_rederive")
      .. "\n\n" .. ready_split_canonicalized_marker(
        proposal_id,
        from_version,
        to_version,
        to_state,
        gate and gate.reason or "ready_split_rederive"
      )
      .. "\n",
    body_after_marker = body_after_marker,
    comment_dedup_key = base_ids.dedup_key({
      "ready-split", "canonicalized", tostring(proposal_id), tostring(from_version), tostring(to_version),
    }),
    label_policy = {
      dedup_key = label_dedup_key,
      add_labels = add_labels,
      remove_labels = remove_labels,
    },
    source_ref = issue.source_ref,
  })
  local label_request = comment_request.handoff.label_request
  local emitted = {
    "github-proxy.github_issue_comment_request",
  }
  for _, queue in ipairs(additional_raised or {}) do
    table.insert(emitted, queue)
  end
  devloop_logging.log_apply(dept, proposal_id, to_state, to_version, {
    add = label_request.add_labels,
    remove = label_request.remove_labels,
  }, emitted)
  devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", comment_request)
end

function M.canonicalize_legacy_ready_dependency_wait(dept, issue, state, facts)
  if type(state) ~= "table" or state.state ~= "ready" then
    return false
  end
  local proposal_id = facts and facts.proposal_id or state.proposal_id
  local current = facts and facts.current
  local comments = current and current.comments
  if proposal_id == nil or type(comments) ~= "table" then
    return false
  end
  if M.ready_split_canonicalized_fact(comments, proposal_id, state.version) ~= nil then
    return false
  end
  if M.dependency_hold_fact(comments, proposal_id) == nil then
    return false
  end
  local gate = facts.dependency_gate or M.dependency_gate(issue.repo, issue.number, {
    proposal_id = proposal_id,
    version = state.version,
    comments = comments,
  })
  local to_state = dependency_gate.dependency_gate_is_satisfied(gate) and "ready" or "dependency_wait"
  local to_version = M.ready_split_version(state.version)
  local label_dedup_key = to_state == "dependency_wait"
    and base_ids.dedup_key({ "dependency", "label", "hold", tostring(proposal_id), tostring(to_version), tostring(gate.hold_kind) })
    or base_ids.dedup_key({ "dependency", "label", "clear", tostring(proposal_id), tostring(to_version) })
  devloop_logging.log_cas_decision(dept, proposal_id, state, "ready", to_state, "applied(ready-split-canonicalized)", gate.reason or "ready_split_rederive")
  M.raise_ready_split_effects(dept, issue, proposal_id, state.version, to_state, to_version, gate, label_dedup_key)
  return true
end

local function replay_fields(M, row, state, issue, proposal_id)
  return replay_fields_resolver.resolve(row, state, {
    issue = issue,
    state = state,
    proposal_id = proposal_id,
  }, entity_lib.pr_source_ref)
end

local function read_fact(facts, family)
  if type(facts) ~= "table" then
    return nil
  end
  local direct = facts[family]
  if direct ~= nil then
    return direct
  end
  return facts[tostring(family or ""):gsub("%-", "_")]
end

local function dependency_gate_fact(M, dept, proposal_id, state, facts)
  local gate = read_fact(facts, "dependency-gate")
  if gate ~= nil then
    return gate
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, state.state, state.state, "skip-pending(dependency-gate-missing)", "declared dependency-gate fact is not visible")
  return nil
end

function M.replay_row_and_facts_with_declared_dependency_gate(issue, proposal_id, state, current, command)
  local row = replay_fields_resolver.restart_transition_row(M.restart_transition_table(), state.state)
  local facts = { proposal_id = proposal_id, current = current, command = command }
  for _, advancing_fact in ipairs(row and row.advancing_facts or {}) do
    if advancing_fact.fact_family == "dependency-gate"
      or advancing_fact.fact_family == "implementation-supervision-result" then
      facts.dependency_gate = M.dependency_gate(issue.repo, issue.number, {
        proposal_id = proposal_id, version = state.version, comments = current.comments,
      })
      break
    end
  end
  return row, facts
end

local function raise_dependency_release(M, dept, issue, proposal_id, state, command_comment_request, gate, release_fact)
  local ready_version = M.ready_split_version(state.version)
  local additional_raised = {}
  if release_fact == nil then table.insert(additional_raised, "github-proxy.github_issue_comment_request") end
  if command_comment_request ~= nil then table.insert(additional_raised, "github-proxy.github_issue_comment_request") end
  M.raise_ready_split_effects(dept, issue, proposal_id, state.version, "ready", ready_version, gate,
    base_ids.dedup_key({ "dependency", "label", "clear", tostring(proposal_id), tostring(state.version) }), additional_raised)
  if command_comment_request ~= nil then
    devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", command_comment_request)
  end
  if release_fact == nil then
    devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", requests_lifecycle.build_dependency_release_comment_request(M,
      issue.repo, issue.number, proposal_id, state.version, gate, issue.source_ref
    ))
  end
  return true
end

local function raise_dependency_wait_hold(M, dept, issue, proposal_id, state, current, gate, command, dependency_hold)
  local marker = gate.hold_kind == "cycle"
    and M.dependency_cycle_marker(proposal_id, state.version)
    or (gate.hold_kind == "unresolvable"
      and M.dependency_unresolvable_marker(proposal_id, state.version, gate.unmet, gate.hold_kind, gate.reason)
      or M.dependency_wait_marker(proposal_id, state.version, gate.unmet, gate.hold_kind, gate.reason))
  devloop_logging.log_cas_decision(dept, proposal_id, state, "dependency_wait", "dependency_wait", "retry-pending(dependency-hold)", gate.reason)
  local raised = {}
  local expected_edge_requests = {}
  for _, blocker_number in ipairs(gate.missing_expected_edges or {}) do
    table.insert(expected_edge_requests, requests_lifecycle.build_expected_dependency_edge_request(
      issue.repo,
      issue.number,
      proposal_id,
      state.version,
      blocker_number,
      issue.source_ref
    ))
    table.insert(raised, "github-proxy.github_issue_blocked_by_request")
  end
  if dependency_hold == nil then
    table.insert(raised, "github-proxy.github_issue_comment_request")
    table.insert(raised, "github-proxy.github_issue_label_request")
  end
  local command_comment_request = nil
  if command ~= nil then
    command_comment_request = operator_commands.build_operator_issue_reready_comment_request(issue.repo, issue.number, command, "dependency-hold", issue.source_ref)
    table.insert(raised, "github-proxy.github_issue_comment_request")
  end
  if #raised > 0 then
    local add_labels = dependency_hold == nil and { M._blocked_on_dependency_label } or {}
    devloop_logging.log_apply(dept, proposal_id, "dependency_wait", state.version, { add = add_labels, remove = {} }, raised)
  end
  if command_comment_request ~= nil then
    devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", command_comment_request)
  end
  if dependency_hold == nil then
    devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", requests_lifecycle.build_dependency_hold_comment_request(M, issue.repo, issue.number, proposal_id, state.version, gate, marker, issue.source_ref))
    devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_label_request", requests_labels.build_label_request(issue.repo, issue.number, { M._blocked_on_dependency_label }, {},
      base_ids.dedup_key({ "dependency", "label", "hold", tostring(proposal_id), tostring(state.version), tostring(gate.hold_kind) }), issue.source_ref
    ))
  end
  for _, request in ipairs(expected_edge_requests) do
    devloop_logging.log_raise(
      dept, proposal_id, "github-proxy.github_issue_blocked_by_request", request)
  end
  return #raised > 0
end

local function raise_dependency_gate_blocked(M, dept, issue, proposal_id, state, gate)
  local add_labels, remove_labels = devloop_state.state_label_changes("blocked")
  table.insert(remove_labels, M._blocked_on_dependency_label)
  local comment_request = m_claims.attach_issue_claim({
    schema = "github-proxy.v1",
    repo = issue.repo,
    issue_number = issue.number,
    body = "github-devloop dependency gate blocked"
      .. "\n\n" .. comment_strings.comment_string(M, "reason_block_label") .. "\n" .. tostring(gate.reason or "dependency-gate-unresolvable")
      .. "\n\n" .. devloop_state.state_marker(proposal_id, "blocked", state.version),
    dedup_key = base_ids.dedup_key({ "dependency", "blocked", tostring(proposal_id), tostring(state.version), tostring(gate.kind), tostring(gate.reason) }),
    source_ref = base_ids.normalize_source_ref(issue.source_ref),
  }, issue.source_ref)
  local label_request = requests_labels.build_state_label_request(issue.repo,
    issue.number,
    "blocked",
    proposal_id,
    state.version,
    base_ids.dedup_key({ "dependency", "blocked", "label", tostring(proposal_id), tostring(state.version), tostring(gate.kind), tostring(gate.reason) }),
    issue.source_ref
  )
  table.insert(label_request.remove_labels, M._blocked_on_dependency_label)
  devloop_logging.log_cas_decision(dept, proposal_id, state, "dependency_wait", "blocked", "applied(dependency-gate-unresolvable)", gate.reason)
  return replay_fields_resolver.replay_raise_effects(devloop_logging.log_apply, devloop_logging.log_raise, dept, proposal_id, "blocked", state.version, { add = add_labels, remove = remove_labels }, {
    { queue = "github-proxy.github_issue_comment_request", payload = comment_request },
    { queue = "github-proxy.github_issue_label_request", payload = label_request },
  })
end

local function blocked_dependency_reready_reentry(state, facts)
  local reentry = type(state) == "table" and state.operator_reentry or nil
  local origin = type(reentry) == "table" and reentry.dependency_origin or nil
  local command = type(facts) == "table" and facts.command or nil
  if state.state ~= "dependency_wait"
    or type(reentry) ~= "table"
    or reentry.command ~= "reready"
    or reentry.from_state ~= "blocked"
    or reentry.boundary ~= "dependency-hold"
    or type(origin) ~= "table"
    or tostring(origin.version or "") ~= tostring(state.version or "")
    or type(command) ~= "table"
    or command.command ~= "reready" then
    return nil
  end
  return reentry
end

local function replay_blocked_dependency_reready(M, dept, issue, proposal_id, state, facts, gate, reentry)
  local target_state = nil
  if dependency_gate.dependency_gate_is_satisfied(gate) then
    target_state = "ready"
  elseif gate.kind == "waiting" then
    target_state = "dependency_wait"
  elseif not dependency_gate.dependency_gate_is_verified_cannot_proceed(gate, issue.repo, issue.number)
    and gate.kind ~= "unavailable" then
    error("github-devloop: dependency-reready-gate-invalid: fresh dependency gate has no supported outcome")
  end

  local response_state = target_state or "blocked"
  local response = operator_commands.build_operator_issue_reready_comment_request(
    issue.repo, issue.number, facts.command, response_state, issue.source_ref)
  if target_state == nil then
    devloop_logging.log_cas_decision(dept, proposal_id, state, reentry.from_state, "blocked",
      "applied(operator-reready-blocked)", gate.reason)
    devloop_logging.log_apply(dept, proposal_id, nil, nil, { add = {}, remove = {} }, {
      "github-proxy.github_issue_comment_request",
    })
    devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", response)
    return true
  end

  local target_version = M.ready_split_version(state.version)
  local label_dedup_key = target_state == "dependency_wait"
    and base_ids.dedup_key({ "dependency", "label", "hold", tostring(proposal_id), tostring(target_version), tostring(gate.hold_kind) })
    or base_ids.dedup_key({ "dependency", "label", "clear", tostring(proposal_id), tostring(target_version) })
  devloop_logging.log_cas_decision(dept, proposal_id, state, reentry.from_state, target_state,
    "applied(operator-reready-dependency-replay)", gate.reason)
  M.raise_ready_split_effects(dept, issue, proposal_id, state.version, target_state, target_version, gate,
    label_dedup_key, { "github-proxy.github_issue_comment_request" })
  devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", response)
  return true
end

function M.replay_dependency_wait_state(dept, issue, state, row, facts)
  local proposal_id = facts.proposal_id
  local gate = dependency_gate_fact(M, dept, proposal_id, state, facts)
  if gate == nil then
    return false
  end
  local reentry = blocked_dependency_reready_reentry(state, facts)
  if reentry ~= nil then
    return replay_blocked_dependency_reready(M, dept, issue, proposal_id, state, facts, gate, reentry)
  end
  if dependency_gate.dependency_gate_is_verified_cannot_proceed(gate, issue.repo, issue.number) then
    return raise_dependency_gate_blocked(M, dept, issue, proposal_id, state, gate)
  end
  if not dependency_gate.dependency_gate_is_satisfied(gate) then
    return raise_dependency_wait_hold(M, dept, issue, proposal_id, state, facts.current, gate, facts.command, read_fact(facts, "dependency-wait"))
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, "dependency_wait", "ready", "release-dependency-hold", gate.reason)
  local command_comment_request = facts.command_comment_request or (facts.command ~= nil
    and operator_commands.build_operator_issue_reready_comment_request(issue.repo, issue.number, facts.command, "dependency-release", issue.source_ref)
    or nil)
  return raise_dependency_release(M, dept, issue, proposal_id, state, command_comment_request, gate, read_fact(facts, "dependency-release"))
end

local function next_ready_redrive_version(marker_version, round)
  return tostring(marker_version or "") .. "/redrive/ready/" .. tostring(round)
end

local function ready_redrive_round(M, comments, proposal_id, marker_version, row)
  local timeout_round = conv_attempts.timeout_attempt_round(M,
    comments,
    proposal_id,
    marker_version,
    row.from_state
  ) or 0
  local command_round = operator_commands.operator_command_response_count(comments, "reready", "applied", "ready")
  return math.max(timeout_round, command_round) + 1
end

function M.replay_ready_state(dept, issue, state, row, facts)
  local proposal_id = facts.proposal_id
  local fields = replay_fields(M, row, state, issue, proposal_id)
  local gate = dependency_gate_fact(M, dept, proposal_id, state, facts)
  if gate == nil then
    return false
  end
  if not dependency_gate.dependency_gate_is_satisfied(gate) then
    local dep_version = M.ready_split_version(state.version)
    devloop_logging.log_cas_decision(dept, proposal_id, state, "ready", "dependency_wait", "hold-dependency-reappeared", gate.reason)
    M.raise_ready_split_effects(dept, issue, proposal_id, state.version, "dependency_wait", dep_version, gate,
      base_ids.dedup_key({ "dependency", "label", "hold", tostring(proposal_id), tostring(dep_version), tostring(gate.hold_kind) }))
    return true
  end
  local ready_comment_id = devloop_state.ready_hand_off_comment_id(
    facts.current.comments,
    proposal_id,
    state.version
  )
  if ready_comment_id == nil then
    devloop_logging.log_cas_decision(dept, proposal_id, state, "ready", "implementing", "skip-pending(ready-marker-comment-not-visible)", "trusted ready state marker comment id is not visible")
    return false
  end
  local redrive_round = ready_redrive_round(
    M,
    facts.current.comments,
    proposal_id,
    state.version,
    row
  )
  local ready_payload = payloads_builders.build_devloop_ready_payload(M, {
    proposal_id = fields.proposal_id,
    dedup_key = next_ready_redrive_version(state.version, redrive_round),
    source_ref = fields.source_ref,
    effect_version = state.version,
    include_ready_hand_off = true,
    ready_comment_id = ready_comment_id,
  })
  local raised = { "devloop_ready" }
  local command_comment_request = nil
  if facts.command ~= nil then
    command_comment_request = operator_commands.build_operator_issue_reready_comment_request(issue.repo, issue.number, facts.command, "ready", issue.source_ref)
    table.insert(raised, "github-proxy.github_issue_comment_request")
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, "ready", "implementing", "applied(replay)", "dependency gate is satisfied")
  devloop_logging.log_apply(dept, proposal_id, nil, nil, { add = {}, remove = {} }, raised)
  if command_comment_request ~= nil then
    devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_comment_request", command_comment_request)
  end
  devloop_logging.log_raise(dept, proposal_id, "devloop_ready", ready_payload)
  return true
end

return {
  dependency_wait = M.replay_dependency_wait_state,
  ready = M.replay_ready_state,
}
end

return S
