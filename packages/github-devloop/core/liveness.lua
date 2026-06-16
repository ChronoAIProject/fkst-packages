local S = {}

function S.install(M)
local max_timeout_attempts = 3

local function has_required_table(row, field)
  return type(row[field]) == "table" and next(row[field]) ~= nil
end

local function valid_budget(row)
  return type(row.budget) == "table"
    and tonumber(row.budget.minutes) ~= nil
    and tonumber(row.budget.minutes) > 0
end

local function valid_timeout(row)
  if type(row.on_timeout) ~= "table" then
    return false
  end
  if row.on_timeout.action ~= "redrive" or row.on_timeout.queue ~= row.driving_queue then
    return false
  end
  if tonumber(row.on_timeout.escalate_after_attempts) == nil
    or tonumber(row.on_timeout.escalate_after_attempts) <= 0 then
    return false
  end
  local terminal = row.on_timeout.on_escalate
  return type(terminal) == "table"
    and terminal.action == "force-terminate"
    and terminal.terminal_state == "blocked"
    and type(terminal.reason) == "string"
    and terminal.reason ~= ""
end

function M.liveness_contract_errors(rows)
  local errors = {}
  for _, row in ipairs(rows or M.restart_transition_table()) do
    if type(row.from_state) ~= "string" or row.from_state == "" then
      table.insert(errors, "row: missing from_state")
    end
    if type(row.terminal) ~= "boolean" then
      table.insert(errors, tostring(row.from_state or "?") .. ": terminal must be boolean")
    end
    if row.terminal == true then
      if row.output_obligation ~= nil then
        table.insert(errors, tostring(row.from_state or "?") .. ": terminal row must not declare output_obligation")
      end
    else
      if not has_required_table(row, "output_obligation") then
        table.insert(errors, tostring(row.from_state or "?") .. ": non-terminal row must declare output_obligation")
      end
      if not valid_budget(row) then
        table.insert(errors, tostring(row.from_state or "?") .. ": non-terminal row must declare a positive budget")
      end
      if not valid_timeout(row) then
        table.insert(errors, tostring(row.from_state or "?") .. ": non-terminal row must declare redrive on_timeout for its driving queue plus force-terminate on_escalate to blocked")
      end
      if (type(row.to_states) ~= "table" or #row.to_states == 0)
        and (type(row.reentry_commands) ~= "table" or #row.reentry_commands == 0) then
        table.insert(errors, tostring(row.from_state or "?") .. ": non-terminal row must declare at least one next state")
      end
    end
    for _, next_state in ipairs(row.to_states or {}) do
      if M._label_by_state[next_state] == nil then
        table.insert(errors, tostring(row.from_state or "?") .. ": unknown next state " .. tostring(next_state))
      end
    end
  end
  return errors
end

function M.liveness_terminal_states(rows)
  local terminals = {}
  for _, row in ipairs(rows or M.restart_transition_table()) do
    if row.terminal == true then
      table.insert(terminals, row.from_state)
    end
  end
  return terminals
end

function M.issue_marker_liveness_sweep_states(rows)
  local states = {}
  for _, row in ipairs(rows or M.restart_transition_table()) do
    if row.terminal == false then
      states[row.from_state] = true
    end
  end
  return states
end

function M.issue_marker_liveness_sweep_contract_errors(rows, sweep_states)
  local errors = {}
  local declared_states = sweep_states or M.issue_marker_liveness_sweep_states(rows)
  for _, row in ipairs(rows or M.restart_transition_table()) do
    if row.terminal == false and declared_states[row.from_state] ~= true then
      table.insert(errors, tostring(row.from_state or "?") .. ": non-terminal issue-marker state is not reachable by liveness sweep")
    end
    if row.terminal == true and declared_states[row.from_state] == true then
      table.insert(errors, tostring(row.from_state or "?") .. ": terminal issue-marker state must not be re-driven by liveness sweep")
    end
  end
  return errors
end

function M.liveness_budget_minutes(state_name)
  local row = M.restart_transition_row(state_name)
  return row and row.budget and tonumber(row.budget.minutes) or nil
end

function M.liveness_state_age_minutes(state, now_seconds)
  if type(state) ~= "table" then
    return nil
  end
  if state.marker_created_at ~= nil and state.marker_created_at ~= "" then
    local created_seconds = M.iso_timestamp_epoch_seconds(state.marker_created_at)
    local current_seconds = tonumber(now_seconds)
    if created_seconds ~= nil and current_seconds ~= nil and current_seconds >= created_seconds then
      return math.floor((current_seconds - created_seconds) / 60)
    end
  end
  return M.stall_suspect_age_minutes(state.version, now_seconds)
end

function M.liveness_timeout_attempt(row, state, facts)
  local proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id)
  local comments = facts and facts.current and facts.current.comments or nil
  local from_state = row and row.from_state
  local version = state and state.version
  local durable_round = M.timeout_attempt_round(comments, proposal_id, version, from_state)
  local version_round = M.version_timeout_round(version, from_state)
  return math.max(durable_round or 0, version_round or 0)
end

function M.next_liveness_timeout_version(row, state, facts)
  local from = tostring(row.from_state)
  local escaped = from:gsub("%-", "%%-")
  local base = tostring(state and state.version or "")
  -- Replace, not stack, the trailing timeout segment for this state so the version
  -- stays bounded as attempts climb: V -> V/timeout/<state>/1 -> V/timeout/<state>/2.
  -- The attempt count itself is read from the full (pre-strip) version, so it keeps
  -- advancing across sweeps even though the suffix never accumulates.
  local previous = nil
  while previous ~= base do
    previous = base
    base = base:gsub("/timeout/" .. escaped .. "/%d+$", "")
  end
  return base .. "/timeout/" .. from .. "/" .. tostring(M.liveness_timeout_attempt(row, state, facts) + 1)
end

function M.liveness_timeout_due(row, state, now_seconds)
  if row == nil or row.terminal == true then
    return false, nil
  end
  local budget = row.budget and tonumber(row.budget.minutes) or nil
  local age = M.liveness_state_age_minutes(state, now_seconds)
  if budget == nil or age == nil or age < budget then
    return false, age
  end
  return true, age
end

local function timeout_escalation(row, state, age, facts)
  local attempt = M.liveness_timeout_attempt(row, state, facts)
  local limit = tonumber(row.on_timeout and row.on_timeout.escalate_after_attempts) or max_timeout_attempts
  local next_version = M.next_liveness_timeout_version(row, state, facts)
  if attempt >= limit then
    return {
      action = "escalate",
      attempt = attempt,
      age_minutes = age,
    }
  end
  if attempt + 1 >= limit then
    return {
      action = "escalate",
      attempt = attempt + 1,
      age_minutes = age,
    }
  end
  return {
    action = "redrive",
    attempt = attempt + 1,
    age_minutes = age,
    version = next_version,
  }
end

local function build_timeout_reconcile(row, entity, state, facts, decision)
  local source_ref = (facts and facts.source_ref) or (entity and entity.source_ref) or (state and state.source_ref)
  local proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id)
  if M._has_bounded_source_ref(source_ref)
    and M._is_path_safe_key(proposal_id, M._max_key_len)
    and M._is_bounded_string(state and state.version, M._max_dedup_len) then
    return "devloop_timeout_reconcile", M.build_devloop_timeout_reconcile_payload(row, state, proposal_id, source_ref, decision.attempt)
  end
  return nil, nil
end

function M.build_liveness_timeout_reconcile_payload(row, entity, state, facts, decision)
  return build_timeout_reconcile(row, entity, state, facts, decision)
end

function M.liveness_timeout_decision(row, state, now_seconds)
  local due, age = M.liveness_timeout_due(row, state, now_seconds)
  if not due then
    return {
      action = "wait",
      age_minutes = age,
    }
  end
  return timeout_escalation(row, state, age)
end

function M.liveness_timeout_decision_with_facts(row, state, facts, now_seconds)
  local due, age = M.liveness_timeout_due(row, state, now_seconds)
  if not due then
    return {
      action = "wait",
      age_minutes = age,
    }
  end
  return timeout_escalation(row, state, age, facts)
end

local function timeout_attempt_target(entity, facts)
  local source_ref = (facts and facts.source_ref) or (entity and entity.source_ref)
  local kind = "issue"
  local repo = entity and entity.repo
  local number = entity and entity.number
  local _, pr_number = M.parse_pr_source_ref(source_ref)
  if pr_number ~= nil then
    local parsed_repo = select(1, M.parse_proposal_id(facts and facts.proposal_id))
    kind = "pr"
    repo = parsed_repo or repo
    number = pr_number
  end
  if kind == "issue" then
    local parsed_repo, issue_number = M.parse_proposal_id(facts and facts.proposal_id)
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
    local attempt_request = M.build_timeout_attempt_comment_request(target, proposal_id, state, row, source_ref, attempt)
    M.log_raise(dept, proposal_id, target.kind == "pr" and "github-proxy.github_pr_comment_request" or "github-proxy.github_issue_comment_request", attempt_request)
  end
end

local function emit_decompose_exhausted_marker(dept, entity, state, facts, proposal_id, attempt)
  local target = timeout_attempt_target(entity, facts)
  local source_ref = (facts and facts.source_ref) or (entity and entity.source_ref) or (state and state.source_ref)
  if target ~= nil then
    local request = M.build_decompose_exhausted_comment_request(target, proposal_id, state, source_ref, attempt)
    M.log_apply(dept, proposal_id, nil, nil, { add = {}, remove = {} }, {
      target.kind == "pr" and "github-proxy.github_pr_comment_request" or "github-proxy.github_issue_comment_request",
    })
    M.log_raise(dept, proposal_id, target.kind == "pr" and "github-proxy.github_pr_comment_request" or "github-proxy.github_issue_comment_request", request)
    return true
  end
  return false
end

function M.maybe_timeout_redrive_from_table(dept, entity, state, table_row, facts)
  local row = table_row or M.restart_transition_row(state and state.state)
  if row == nil or row.terminal == true then
    return false
  end
  local comments = facts and facts.current and facts.current.comments or nil
  local proposal_id = facts and facts.proposal_id or state and state.proposal_id
  if row.from_state == "blocked" and M.has_decompose_exhausted_marker(comments, proposal_id, state and state.version) then
    M.log_cas_decision(dept, proposal_id, state, "blocked", row.driving_queue, "skip-idempotent(decompose-exhausted)", "blocked decompose output obligation already reached terminal stop")
    return true
  end
  local decision = M.liveness_timeout_decision_with_facts(row, state, facts, (facts and facts.now_seconds) or now())
  if decision.action == "wait" then
    return false
  end
  M.log_cas_decision(dept, proposal_id, state, row.from_state, row.driving_queue, "timeout-" .. decision.action, "state output obligation exceeded budget")
  if decision.action == "escalate" then
    if row.from_state == "blocked" then
      return emit_decompose_exhausted_marker(dept, entity, state, facts, proposal_id, decision.attempt)
    end
    local queue, payload = build_timeout_reconcile(row, entity, state, facts, decision)
    if queue ~= nil then
      M.log_apply(dept, proposal_id, nil, nil, { add = {}, remove = {} }, { queue })
      M.log_raise(dept, proposal_id, queue, payload)
      return true
    end
    return false
  end
  local issued = M.replay_from_table(dept, entity, {
    state = state.state,
    version = state.version,
    proposal_id = state.proposal_id,
    stage_rank = state.stage_rank,
    marker_created_at = state.marker_created_at,
  }, row, facts)
  if issued then
    emit_timeout_attempt_marker(dept, entity, state, row, facts, proposal_id, decision.attempt)
  end
  return issued
end

end

return S
