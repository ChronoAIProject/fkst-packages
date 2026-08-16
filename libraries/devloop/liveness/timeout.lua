local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local strings = require("contract.strings")
local conv_reconcile = require("devloop.convergence.reconcile")
local conv_attempts = require("devloop.convergence.attempts")
local m_rae = require("devloop.restart_actionable_epoch")
local S = {}
local contract_time = require("contract.time")
local source_refs = require("contract.source_ref")
local replay_fields = require("devloop.replay_fields")
local devloop_logging = require("devloop.logging")
local transition_version = require("contract.transition_version")

function S.new(policy, shared, resolved)
local K = {}
local replayer = assert(resolved and resolved.replayer,
  "devloop.liveness.timeout: missing replayer capability")
assert(type(replayer.replay_from_table_classified) == "function",
  "devloop.liveness.timeout: missing replay_from_table_classified")
local max_timeout_attempts = shared.max_timeout_attempts
local numeric_minutes = shared.numeric_minutes
local row_liveness_signal = shared.row_liveness_signal

function K.liveness_state_age_minutes(state, now_seconds)
  if type(state) ~= "table" then
    return nil
  end
  return contract_time.iso_timestamp_age_minutes(state.marker_created_at, now_seconds)
    or policy.stall_suspect_age_minutes(state.version, now_seconds)
end

function K.liveness_timeout_attempt(row, state, facts)
  local eval = facts and facts.actionable_epoch_eval
  if m_rae.restart_row_has_registered_actionable_epoch(policy, row) then
    return m_rae.actionable_epoch_timeout_attempt(row, state, facts)
  end
  local proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id)
  local comments = facts and facts.current and facts.current.comments or nil
  local from_state = row and row.from_state
  local version = state and state.version
  local durable_round = conv_attempts.timeout_attempt_round(comments, proposal_id, version, from_state)
  local version_round = policy.version_timeout_round(version, from_state)
  return math.max(durable_round or 0, version_round or 0)
end

function K.next_liveness_timeout_version(row, state, facts)
  local from = tostring(row.from_state)
  -- Replace, not stack, the trailing timeout segment for this state so the version
  -- stays bounded as attempts climb: V -> V/timeout/<state>/1 -> V/timeout/<state>/2.
  -- The attempt count itself is read from the full (pre-strip) version, so it keeps
  -- advancing across sweeps even though the suffix never accumulates.
  return transition_version.timeout_at(state and state.version, from, K.liveness_timeout_attempt(row, state, facts) + 1)
end

function K.liveness_timeout_due(row, state, now_seconds)
  if row == nil or row.terminal == true then
    return false, nil
  end
  local budget = row.budget and tonumber(row.budget.minutes) or nil
  local age = K.liveness_state_age_minutes(state, now_seconds)
  if budget == nil or age == nil or age < budget then
    return false, age
  end
  return true, age
end

local function live_signal_max_age(row)
  return numeric_minutes(row_liveness_signal(row) and row_liveness_signal(row).max_age_minutes)
end

function K.liveness_timeout_due_with_facts(row, state, facts, now_seconds)
  if row == nil or row.terminal == true then
    return false, nil
  end
  if m_rae.restart_row_has_registered_actionable_epoch(policy, row) then
    return m_rae.actionable_epoch_timeout_due(policy, row, state, facts, now_seconds)
  end
  local contract = row.liveness_contract
  if type(contract) == "table" and contract.mode == "row-budget-bounds-receiver" then
    return K.liveness_timeout_due(row, state, now_seconds)
  end
  local signal_max_age = live_signal_max_age(row)
  if signal_max_age ~= nil then
    local signal = policy.restart_row_liveness_signal(row, state, facts, now_seconds)
    if signal.age_minutes ~= nil then
      if signal.age_minutes < signal_max_age then
        return false, signal.age_minutes
      end
      return true, signal.age_minutes
    end
  end
  return K.liveness_timeout_due(row, state, now_seconds)
end

-- Owner directive (issue ChronoAIProject/fkst-packages#2725): a TIMEOUT — or any
-- transient / liveness / resource / attempt-counter / round-budget condition — must
-- NEVER transition a devloop entity to a terminal state (blocked). Only an EXPLICIT
-- cannot-proceed (consensus reject / explicit operator block) may reach terminal, via
-- its own dedicated edge. The raw `escalate_after_attempts` counter therefore no
-- longer forces termination: a state past its output-obligation budget REDRIVES
-- indefinitely. Liveness is still bounded by the upstream gates that run before this
-- function — `restart_row_receiver_liveness` (`action="defer"` while a receiver is
-- provably live) and `liveness_timeout_due*` (`action="wait"` before budget) — so the
-- redrive is gated by real liveness/progress, not by a raw count. The `on_escalate`
-- config (force-terminate/blocked) is retained on rows so the CAS grant-facade edge
-- synthesis + frozen timeout-reconcile parity corpus stay byte-exact (conservative
-- extension), but the live watchdog never produces an `escalate` decision, so those
-- terminal edges are no longer traversed at runtime.
local function redrive_resolver_diagnostics(row, facts)
  local eval = facts and facts.actionable_epoch_eval
  local observed = type(eval) == "table" and eval.signal or nil
  local contract = row and row.liveness_contract
  local declared_signal = type(contract) == "table" and contract.signal or nil
  local resolver = type(observed) == "table" and observed.resolver
    or type(contract) == "table" and type(contract.real_execution) == "table" and contract.real_execution.primitive
    or type(declared_signal) == "table" and (declared_signal.resolver or declared_signal.family)
    or (row and type(row.child_dependency) == "table" and row.child_dependency.predicate or nil)
  if resolver == nil then
    return "none", "not-declared"
  end
  local verdict = type(observed) == "table" and observed.reason
    or type(eval) == "table" and eval.reason
    or type(observed) == "table" and observed.state
  if verdict == nil and type(observed) == "table" and observed.live ~= nil then
    verdict = observed.live and "live" or "not-live"
  end
  return tostring(resolver), tostring(verdict or "not-reported")
end

local function with_redrive_diagnostics(row, facts, decision)
  if type(decision) ~= "table" or decision.action ~= "redrive" then
    return decision
  end
  decision.budget_minutes = row and row.budget and tonumber(row.budget.minutes) or nil
  decision.resolver, decision.verdict = redrive_resolver_diagnostics(row, facts)
  return decision
end

local function timeout_escalation(row, state, age, facts)
  local attempt = K.liveness_timeout_attempt(row, state, facts)
  return with_redrive_diagnostics(row, facts, {
    action = "redrive",
    attempt = attempt + 1,
    age_minutes = age,
    version = K.next_liveness_timeout_version(row, state, facts),
  })
end

local function build_timeout_reconcile(row, entity, state, facts, decision)
  local source_ref = (facts and facts.source_ref) or (entity and entity.source_ref) or (state and state.source_ref)
  local proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id)
  if source_refs.has_bounded_source_ref(source_ref, policy._max_key_len)
    and strings.is_path_safe_key(proposal_id, policy._max_key_len)
    and strings.is_bounded_string(state and state.version, policy._max_dedup_len) then
    return "devloop_timeout_reconcile", conv_reconcile.build_devloop_timeout_reconcile_payload(row, state, proposal_id, source_ref, decision.attempt)
  end
  return nil, nil
end

function K.liveness_timeout_decision(row, state, now_seconds)
  local due, age = K.liveness_timeout_due(row, state, now_seconds)
  if not due then
    return {
      action = "wait",
      age_minutes = age,
    }
  end
  return timeout_escalation(row, state, age)
end

function K.liveness_timeout_decision_with_facts(row, state, facts, now_seconds)
  local due, age = K.liveness_timeout_due_with_facts(row, state, facts, now_seconds)
  local limit = tonumber(row and row.on_timeout and row.on_timeout.escalate_after_attempts) or max_timeout_attempts
  local heartbeat = m_rae.actionable_epoch_heartbeat_decision(policy, row, state, facts, due, age, limit)
  if heartbeat ~= nil then return with_redrive_diagnostics(row, facts, heartbeat) end
  local codex_run = m_rae.actionable_epoch_codex_run_decision(policy, row, state, facts, due, age)
  if codex_run ~= nil then return with_redrive_diagnostics(row, facts, codex_run) end
  local child_workflow = m_rae.actionable_epoch_child_workflow_decision(row, state, facts, due, age)
  if child_workflow ~= nil then return with_redrive_diagnostics(row, facts, child_workflow) end
  if not due then
    return { action = "wait", age_minutes = age }
  end
  return timeout_escalation(row, state, age, facts)
end

local function timeout_attempt_target(entity, facts)
  local source_ref = (facts and facts.source_ref) or (entity and entity.source_ref)
  local kind = "issue"
  local repo = entity and entity.repo
  local number = entity and entity.number
  local _, pr_number = devloop_base.parse_pr_source_ref(source_ref)
  if pr_number ~= nil then
    local parsed_repo = select(1, base_ids.parse_proposal_id(facts and facts.proposal_id))
    kind = "pr"
    repo = parsed_repo or repo
    number = pr_number
  end
  if kind == "issue" then
    local parsed_repo, issue_number = base_ids.parse_proposal_id(facts and facts.proposal_id)
    repo = parsed_repo or repo
    number = issue_number or number
  end
  if repo == nil or number == nil then
    return nil
  end
  return {
    kind = kind,
    repo = repo,
    number = number,
  }
end

local function emit_timeout_attempt_marker(dept, entity, state, row, facts, proposal_id, attempt)
  local target = timeout_attempt_target(entity, facts)
  local source_ref = (facts and facts.source_ref) or (entity and entity.source_ref) or (state and state.source_ref)
  if target ~= nil then
    local eval = facts and facts.actionable_epoch_eval
    if m_rae.restart_row_has_registered_actionable_epoch(policy, row)
      and type(eval) == "table"
      and eval.status == "actionable"
      and eval.generation_key ~= nil then
      devloop_logging.log_raise(dept, proposal_id, target.kind == "pr" and "github-proxy.github_pr_comment_request" or "github-proxy.github_issue_comment_request", conv_attempts.build_timeout_attempt_v2_comment_request(target, proposal_id, state, row, source_ref, attempt, eval.generation_key))
    else
      devloop_logging.log_raise(dept, proposal_id, target.kind == "pr" and "github-proxy.github_pr_comment_request" or "github-proxy.github_issue_comment_request", conv_attempts.build_timeout_attempt_comment_request(target, proposal_id, state, row, source_ref, attempt))
    end
  end
end

local function emit_decompose_exhausted_marker(dept, entity, state, facts, proposal_id, attempt)
  local target = timeout_attempt_target(entity, facts)
  local source_ref = (facts and facts.source_ref) or (entity and entity.source_ref) or (state and state.source_ref)
  if target ~= nil then
    local request = conv_attempts.build_decompose_exhausted_comment_request(target, proposal_id, state, source_ref, attempt)
    devloop_logging.log_apply(dept, proposal_id, nil, nil, { add = {}, remove = {} }, {
      target.kind == "pr" and "github-proxy.github_pr_comment_request" or "github-proxy.github_issue_comment_request",
    })
    devloop_logging.log_raise(dept, proposal_id, target.kind == "pr" and "github-proxy.github_pr_comment_request" or "github-proxy.github_issue_comment_request", request)
    return true
  end
  return false
end

local function with_redrive_delivery_identity(facts, decision)
  local replay_facts = {}
  for key, value in pairs(facts or {}) do
    replay_facts[key] = value
  end
  local eval = replay_facts.actionable_epoch_eval
  local generation_key = type(eval) == "table" and eval.generation_key or decision.version
  if generation_key == nil or generation_key == "" then
    error("github-devloop: redrive-delivery-generation-missing: redrive has no delivery generation")
  end
  replay_facts.redrive_delivery = {
    generation_key = generation_key,
    attempt = decision.attempt,
  }
  return replay_facts
end

function K.maybe_timeout_redrive_from_table(dept, entity, state, table_row, facts)
  local row = table_row or replay_fields.restart_transition_row(policy.restart_transition_table(), state and state.state)
  if row == nil or row.terminal == true then
    return false
  end
  local comments = facts and facts.current and facts.current.comments or nil
  local proposal_id = facts and facts.proposal_id or state and state.proposal_id
  local matches, mismatch = policy.timeout_lineage_matches_current(state, facts and facts.fresh_current_state)
  if not matches then
    devloop_logging.log_cas_decision(dept, proposal_id, facts and facts.fresh_current_state or state, row.from_state, row.driving_queue, "stale_timeout_noop(" .. tostring(mismatch) .. ")", "timeout watchdog lineage no longer matches freshly derived current state")
    return true
  end
  if row.from_state == "blocked" and conv_attempts.has_decompose_exhausted_marker(comments, proposal_id, state and state.version) then
    devloop_logging.log_cas_decision(dept, proposal_id, state, "blocked", row.driving_queue, "skip-idempotent(decompose-exhausted)", "blocked decompose output obligation already reached terminal stop")
    return true
  end
  if row.from_state == "implementing"
    and policy.implementing_version_mismatch_budget_exhausted(comments, proposal_id, state and state.version) then
    devloop_logging.log_cas_decision(dept, proposal_id, state, "implementing", row.driving_queue, "skip-idempotent(version-mismatch-exhausted)", "implementing re-drive would hand implement a version-mismatch whose delivery budget is already exhausted (terminal fail-closed)")
    return true
  end
  local receiver_liveness = policy.restart_row_receiver_liveness(row, state, facts, (facts and facts.now_seconds) or now())
  if receiver_liveness.action == "defer" then
    local signal = receiver_liveness.signal or {}
    local reason = signal.family == "codex_run:v1"
      and "deferred: receiver still executing"
      or "receiver liveness contract signal is still fresh"
    devloop_logging.log_cas_decision(dept, proposal_id, state, row.from_state, row.driving_queue, "skip-timeout-count(live-signal:" .. tostring(signal.family or "unknown") .. ")", reason)
    return true
  end
  local decision = K.liveness_timeout_decision_with_facts(row, state, facts, (facts and facts.now_seconds) or now())
  if decision.action == "wait" then
    return false
  end
  local decision_facts = nil
  if decision.action == "redrive" then
    decision_facts = {
      { name = "age_minutes", values = { decision.age_minutes or "" } },
      { name = "budget_minutes", values = { decision.budget_minutes or "" } },
      { name = "resolver", values = { decision.resolver or "none" } },
      { name = "verdict", values = { decision.verdict or "not-reported" } },
      { name = "attempt", values = { decision.attempt or "" } },
    }
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, row.from_state, row.driving_queue, "timeout-" .. decision.action, "state output obligation exceeded budget", decision_facts)
  if decision.action == "escalate" then
    if row.from_state == "blocked" then
      return emit_decompose_exhausted_marker(dept, entity, state, facts, proposal_id, decision.attempt)
    end
    local queue, payload = build_timeout_reconcile(row, entity, state, facts, decision)
    if queue ~= nil then
      devloop_logging.log_apply(dept, proposal_id, nil, nil, { add = {}, remove = {} }, { queue })
      devloop_logging.log_raise(dept, proposal_id, queue, payload)
      return true
    end
    return false
  end
  -- Owner directive (#2725) anti-spin decompose-escape: timeouts/counters REDRIVE and
  -- never drop ACTIVE work to terminal `blocked`, BUT the `blocked` state is ALREADY
  -- terminal and its decompose OUTPUT obligation still needs a bounded terminal STOP so
  -- the redrive loop does not spin forever. Emitting the decompose-exhausted marker once
  -- the attempt budget is reached is NOT a timeout->terminal transition (the issue is
  -- already blocked); it is exactly the "decompose escape" the doctrine requires. This
  -- restores the terminal-stop that previously lived on the (now never-taken) escalate
  -- branch above, without reintroducing any active-state force-terminate.
  if row.from_state == "blocked" then
    local escape_limit = tonumber(row.on_timeout and row.on_timeout.escalate_after_attempts) or max_timeout_attempts
    if escape_limit ~= nil and tonumber(decision.attempt) ~= nil and tonumber(decision.attempt) >= escape_limit then
      return emit_decompose_exhausted_marker(dept, entity, state, facts, proposal_id, decision.attempt)
    end
  end
  local replay = replayer.replay_from_table_classified(dept, entity, {
    state = state.state,
    version = state.version,
    proposal_id = state.proposal_id,
    stage_rank = state.stage_rank,
    marker_created_at = state.marker_created_at,
  }, row, with_redrive_delivery_identity(facts, decision))
  if replay.kind == "deferred" then
    return true
  end
  if replay.kind == "stuck" then
    devloop_logging.log_cas_decision(dept, proposal_id, state, row.from_state, row.driving_queue, "timeout-stuck(" .. tostring(replay.outcome or "replay-declined") .. ")", "state output obligation is unmet and replay did not emit a consumable redrive")
    error("github-devloop: timeout-redrive-stuck: replay did not emit a consumable redrive; outcome="
      .. tostring(replay.outcome or "replay-declined") .. " reason=" .. tostring(replay.reason or "unknown"))
  end
  if replay.kind == "issued" then
    emit_timeout_attempt_marker(dept, entity, state, row, facts, proposal_id, decision.attempt)
    return true
  end
  return false
end

return K
end

return S
