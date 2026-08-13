local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local base_ids = require("devloop.base_ids")
local parsers_pr = require("devloop.parsers.pr")
local parsers_issue = require("devloop.parsers.issue")
local C, replay_fields, sweep_bounds = {}, require("devloop.replay_fields"), require("devloop.sweep_bounds")
local entity_list_cache = require("devloop.entity_list_cache")
local devloop_logging = require("devloop.logging")

local LIVENESS_SCAN_MAX_PER_TICK = 100
local LIVENESS_SCAN_CALL_TIMEOUT = 10
local LIVENESS_SCAN_WALL_CLOCK_BUDGET = 25

function C.liveness_scan_limits()
  return {
    entity_cap = LIVENESS_SCAN_MAX_PER_TICK,
    call_timeout = LIVENESS_SCAN_CALL_TIMEOUT,
    wall_clock_budget = LIVENESS_SCAN_WALL_CLOCK_BUDGET,
  }
end

function C.liveness_scan_read_repo()
  local repo = devloop_base.read_env("FKST_GITHUB_REPO")
  if repo == nil or not base_ids.issue_ref_round_trips(repo, 1) then
    return nil
  end
  return repo
end

function C.liveness_scan_cursor_key(repo, prefix)
  return tostring(prefix or "github-devloop/liveness-scan/cursor/") .. base_ids.safe_repo(repo)
end

function C.liveness_scan_log_deferred(reason, fields)
  local fact_fields = {
    "reason=" .. tostring(reason or "budget"),
    "listed_issues=" .. tostring(fields and fields.listed_issues or 0),
    "listed_prs=" .. tostring(fields and fields.listed_prs or 0),
    "processed=" .. tostring(fields and fields.processed or 0),
    "deferred=" .. tostring(fields and fields.deferred or 0),
    "entity_cap=" .. tostring(fields and fields.entity_cap or 0),
  }
  if fields and fields.error_class ~= nil then
    table.insert(fact_fields, 2, "error_class=" .. tostring(fields.error_class))
  end
  devloop_logging.log_line("info", "liveness_scan", "github-devloop/liveness-scan", "LIVENESS_DEFERRED", fact_fields)
end

function C.liveness_scan_is_timeout_result(M, result)
  return type(result) == "table" and result.exit_code ~= 0
    and (tonumber(result.exit_code) == 124 or M.error_fact_class({ message = result.stderr }) == "timeout")
end

function C.liveness_scan_update_cursor(cursor_key, cursor, total, processed)
  if cursor_key == nil then
    return
  end
  local state = type(cursor) == "table" and cursor or {}
  local attempted = tonumber(processed) or 0
  local remaining = tonumber(state.remaining) or 0
  if attempted >= remaining then
    cache_set(cursor_key, "0")
    return
  end
  local last_attempted = tonumber(state.activation_numbers and state.activation_numbers[attempted])
  if attempted > 0 and last_attempted ~= nil then
    state.last_number = last_attempted
  end
  cache_set(cursor_key, tostring(state.last_number or 0) .. ":" .. tostring(state.high_water or 0))
end

function C.liveness_scan_build_observe_payload(repo, entity, kind, tick)
  local number = tostring(entity.number or "")
  local updated_at = tostring(entity.updated_at or "")
  local source_ref = kind == "pr" and entity_lib.pr_source_ref(repo, number) or entity_lib.issue_source_ref(repo, number)
  return {
    schema = "github-proxy.v1",
    type = kind,
    repo = repo,
    number = tonumber(number), title = entity.title,
    state = entity.state,
    updated_at = updated_at,
    dedup_key = base_ids.dedup_key({
      "liveness-scan",
      tostring(repo),
      kind,
      number,
      updated_at,
      tostring(tick or ""),
    }),
    source = "liveness-scan",
    source_ref = source_ref,
  }
end

local function observe_queue(kind)
  if kind == "pr" then
    return "devloop_observe_pr"
  end
  return "devloop_observe_issue"
end

function C.liveness_scan_build_failure_observe_payload(repo, entity, kind, failure)
  local proposal_id = kind == "pr"
      and entity_lib.pr_proposal_id(repo, entity.number)
    or base_ids.proposal_id(repo, entity.number)
  local queue = observe_queue(kind)
  local error_class = devloop_logging.error_class_from_message(failure)
  local fingerprint = devloop_logging.error_fingerprint(error_class, queue, "liveness_scan", failure)
  local payload = C.liveness_scan_build_observe_payload(repo, entity, kind)
  payload.proposal_id = proposal_id
  payload.dedup_key = base_ids.dedup_key({
    "liveness-scan-failure",
    proposal_id,
    tostring(entity.updated_at or "unknown-lineage"),
    error_class,
    fingerprint,
  })
  payload.failure = {
    error_class = error_class,
    fingerprint = fingerprint,
  }
  return payload
end

function C.liveness_scan_fail_observe_payload(payload)
  local failure = type(payload) == "table" and payload.failure or nil
  if failure == nil then
    return false
  end
  local error_class = type(failure) == "table" and tostring(failure.error_class or "") or ""
  local fingerprint = type(failure) == "table" and tostring(failure.fingerprint or "") or ""
  if payload.source ~= "liveness-scan"
    or not error_class:match("^[a-z0-9][a-z0-9-]*$")
    or not fingerprint:match("^fp%-%d+$") then
    error("github-devloop: liveness-scan-failure-envelope-invalid: malformed entity failure observation", 0)
  end
  error("github-devloop: liveness-scan-entity-failure: liveness scan entity failure"
    .. " cause_error_class=" .. error_class
    .. " proposal_id=" .. tostring(payload.proposal_id or "unknown")
    .. " entity_updated_at=" .. tostring(payload.updated_at or "unknown")
    .. " fingerprint=" .. fingerprint, 0)
end

function C.liveness_scan_state_is_non_terminal(M, state)
  local row = replay_fields.restart_transition_row(M.restart_transition_table(), state and state.state)
  return row ~= nil and row.terminal ~= true
end

function C.liveness_scan_should_reinject_state(M, proposal_id, state, labels)
  if state == nil or state.state == nil then
    devloop_logging.log_cas_decision("liveness_scan", proposal_id, { state = nil, version = nil }, "tick", "observe", "skip-no-state", "no current restart state marker")
    return false
  end
  if type(labels) == "table" and not M.state_label_hint_matches(labels, state.state) then
    devloop_logging.log_cas_decision("liveness_scan", proposal_id, state, "tick", "observe", "reinject-label-projection", "current issue state label does not match the canonical state marker")
    return true, "label-projection-mismatch"
  end
  if not C.liveness_scan_state_is_non_terminal(M, state) then
    devloop_logging.log_cas_decision("liveness_scan", proposal_id, state, "tick", "observe", "skip-terminal", "current restart state is terminal or unknown")
    return false
  end
  return true
end

function C.liveness_scan_issue_entity(repo, issue_number)
  return {
    repo = repo,
    number = issue_number,
    source_ref = entity_lib.issue_source_ref(repo, issue_number),
  }
end

function C.liveness_scan_maybe_timeout_action(M, entity, state, facts)
  local row = replay_fields.restart_transition_row(M.restart_transition_table(), state and state.state)
  if row == nil or row.terminal == true then
    return nil
  end
  if row.actionable_epoch
    and row.actionable_epoch.source == "child_workflow_wait:v1" then
    facts = M.replayer.gather_replay_required_facts(row, entity, state, facts)
  end
  local epoch = row.actionable_epoch
  if type(epoch) == "table"
    and epoch.allows_state_entry_if_never_deferred == true
    and type(facts.dependency_gate) ~= "table" then
    facts.dependency_gate = M.dependency_gate(entity and entity.repo, entity and entity.number, {
      proposal_id = facts.proposal_id or state.proposal_id,
      version = state and state.version,
      comments = facts.current and facts.current.comments,
    })
  end
  if state.state == "ready" then
    facts.dependency_gate = facts.dependency_gate or M.dependency_gate(entity and entity.repo, entity and entity.number, {
      proposal_id = facts.proposal_id or state.proposal_id,
      version = state and state.version,
      comments = facts.current and facts.current.comments,
    })
    if M.canonicalize_legacy_ready_dependency_wait("liveness_scan", entity, state, facts) then
      return "handled"
    end
  end
  local proposal_id = facts.proposal_id or state.proposal_id
  if M.restart_row_liveness_deferred(row, state, facts, facts.now_seconds or now()) then
    devloop_logging.log_cas_decision("liveness_scan", proposal_id, state, row.from_state, row.driving_queue, "skip-active-output-obligation", "receiver liveness contract signal is still fresh")
    return nil
  end
  if M.maybe_timeout_redrive_from_table("liveness_scan", entity, state, row, facts) then
    return "handled"
  end
  return nil
end

function C.liveness_scan_observe_queue(kind)
  return observe_queue(kind)
end

local function rate_limit_deferred_outcome(result)
  if type(result) == "table"
    and result.error_class == "gh-rate-limited"
    and result.retryable == true then
    return {
      status = "deferred",
      reason = result.error_class,
      error_class = result.error_class,
      retryable = true,
    }
  end
  return nil
end

local function parse_entity_list_result(result, parser, failure_prefix)
  if result.exit_code ~= 0 then
    local deferred = rate_limit_deferred_outcome(result)
    if deferred ~= nil then
      return nil, deferred
    end
    error(failure_prefix .. tostring(result.stderr))
  end
  return parser(result.stdout)
end

function C.liveness_scan_list_open_issues(M, repo, timeout, poll_key)
  local list = entity_list_cache.fetch_shared_issue_observe_list(M.gh_issue_list_observe_opts, repo, {
    timeout = timeout or 60,
    poll_key = poll_key,
  })
  return parse_entity_list_result(list, parsers_issue.parse_issue_list_observe, "github-devloop: liveness-scan-issue-list-failed: ")
end

function C.liveness_scan_list_open_prs(M, repo, timeout, poll_key)
  local list = entity_list_cache.fetch_shared_pr_observe_list(M.gh_pr_list_observe_opts, repo, {
    timeout = timeout or 60,
    poll_key = poll_key,
  })
  return parse_entity_list_result(list, parsers_pr.parse_pr_list_observe, "github-devloop: liveness-scan-pr-list-failed: ")
end

local function sort_by_number(items)
  table.sort(items, function(left, right)
    return tonumber(left.number or 0) < tonumber(right.number or 0)
  end)
  return items
end

local function decode_scan_cursor(value)
  local last_number, high_water = tostring(value or ""):match("^(%d+):(%d+)$")
  last_number = tonumber(last_number)
  high_water = tonumber(high_water)
  if last_number == nil or high_water == nil or last_number > high_water then
    return 0, nil
  end
  return last_number, high_water
end

local function entities_in_cursor_cycle(activations, last_number, high_water)
  local eligible = {}
  for _, activation in ipairs(activations) do
    local number = tonumber(activation.entity and activation.entity.number)
    if number ~= nil and number > last_number and number <= high_water then
      table.insert(eligible, activation)
    end
  end
  return eligible
end

function C.liveness_scan_activation_slice(repo, kind, items, cursor_prefix)
  local activations = {}
  for _, entity in ipairs(sort_by_number(items or {})) do
    table.insert(activations, { kind = kind, entity = entity })
  end
  local total = #activations
  local cursor_key = C.liveness_scan_cursor_key(repo, cursor_prefix)
  local last_number, high_water = decode_scan_cursor(cache_get(cursor_key))
  local current_high_water = total > 0 and tonumber(activations[total].entity.number) or 0
  if high_water == nil then
    high_water = current_high_water
  end
  local eligible = entities_in_cursor_cycle(activations, last_number, high_water)
  if total > 0 and #eligible == 0 then
    last_number = 0
    high_water = current_high_water
    eligible = entities_in_cursor_cycle(activations, last_number, high_water)
  end

  local bounded = {}
  local activation_numbers = {}
  for index, activation in ipairs(eligible) do
    if index > LIVENESS_SCAN_MAX_PER_TICK then
      break
    end
    table.insert(bounded, activation)
    table.insert(activation_numbers, tonumber(activation.entity.number))
  end
  local deferred = math.max(0, #eligible - #bounded)
  if deferred > 0 then
    devloop_logging.log_cas_decision("liveness_scan", "github-devloop/liveness-scan", { state = nil, version = nil }, "tick", "observe", "deferred-cap", tostring(deferred) .. " open entities deferred by LIVENESS_SCAN_MAX_PER_TICK")
  end
  return bounded, deferred, cursor_key, {
    last_number = last_number,
    high_water = high_water,
    activation_numbers = activation_numbers,
    remaining = #eligible,
  }, total
end

function C.liveness_scan_reinject(repo, entity, kind, tick)
  local proposal_id = kind == "pr" and entity_lib.pr_proposal_id(repo, entity.number) or base_ids.proposal_id(repo, entity.number)
  local payload = C.liveness_scan_build_observe_payload(repo, entity, kind, tick)
  local queue = C.liveness_scan_observe_queue(kind)
  devloop_logging.log_apply("liveness_scan", proposal_id, nil, nil, { add = {}, remove = {} }, {
    queue,
  })
  devloop_logging.log_raise("liveness_scan", proposal_id, queue, payload)
end

function C.liveness_scan_reinject_failure(repo, entity, kind, failure)
  local payload = C.liveness_scan_build_failure_observe_payload(repo, entity, kind, failure)
  local queue = observe_queue(kind)
  devloop_logging.log_apply("liveness_scan", payload.proposal_id, nil, nil, { add = {}, remove = {} }, {
    queue,
  })
  devloop_logging.log_raise("liveness_scan", payload.proposal_id, queue, payload)
end

return C
