local base_ids = require("devloop.base_ids")
local common = require("departments.observability.common")
local config = require("devloop.config")
local contract_time = require("contract.time")
local devloop_base = require("devloop.base")
local decompose = require("devloop.decompose")
local devloop_state = require("devloop.state")
local conv_reconcile = require("devloop.convergence.reconcile")
local entity_view = require("devloop.github_proxy_entity_view")
local marker_facts = require("devloop.markers.facts")
local marker_shared = require("devloop.markers.shared")
local parsers_misc = require("devloop.parsers.misc")
local forge_strings = require("forge.strings")
local request_shared = require("devloop.requests.shared")
local sweep_bounds = require("devloop.sweep_bounds")

local M = {}

local retirement_receipt_pattern = "<!%-%- fkst:github%-devloop%-ops:terminal%-retirement%-receipt:v1.-%-%->"
local result_marker_pattern = "<!%-%- fkst:github%-devloop:result:v1.-%-%->"
local state_marker_pattern = marker_shared.STATE_MARKER_PATTERN

local function ineligible(reason, elapsed_minutes)
  return {
    decision = "ineligible",
    reason = reason,
    elapsed_minutes = elapsed_minutes,
  }
end

local function exact_marker_value(value, limit)
  local text = tostring(value or "")
  if text == "" or #text > limit or marker_shared.safe_marker_attr(text, limit) ~= text then
    return nil
  end
  return text
end

local function recorded_decline_reason(comments, proposal_id, terminal_version)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(result_marker_pattern) do
      local marker_proposal = marker_shared.marker_attr(marker, "proposal")
      local marker_identity = marker_shared.marker_attr(marker, "lineage")
        or marker_shared.marker_attr(marker, "dedup")
      local decision = marker_shared.marker_attr(marker, "decision")
      local reason = marker_shared.marker_attr(marker, "reason")
      if marker_proposal == proposal_id
        and marker_identity == terminal_version
        and decision == "reject"
        and reason == "premise-refuted" then
        return reason
      end
    end
  end
  return nil
end

local function declined_terminal_marker_position(comments, proposal_id, terminal_version)
  for index, comment in ipairs(comments or {}) do
    if parsers_misc._is_trusted_comment(comment) then
      for marker in parsers_misc._comment_body(comment):gmatch(state_marker_pattern) do
        if marker_shared.marker_attr(marker, "proposal") == proposal_id
          and marker_shared.marker_attr(marker, "state") == "declined"
          and marker_shared.marker_attr(marker, "version") == terminal_version then
          return index, parsers_misc._comment_created_at(comment)
        end
      end
    end
  end
  return nil, nil
end

local function has_post_terminal_non_bot_comment(comments, terminal_marker_index)
  local trusted_bot = forge_strings.canonical_login(parsers_misc.trusted_bot_login())
  for index, comment in ipairs(comments or {}) do
    if index > terminal_marker_index then
      local author = forge_strings.canonical_login(parsers_misc._comment_author_login(comment))
      if forge_strings.canonical_login(author) ~= forge_strings.canonical_login(trusted_bot) then
        return true
      end
    end
  end
  return false
end

local function retirement_receipt_marker(fact)
  if fact.terminal_authority == "reconcile:v1" then
    return '<!-- fkst:github-devloop-ops:terminal-retirement-receipt:v1 proposal="'
      .. fact.proposal_id
      .. '" terminal_state="blocked" terminal_version="' .. fact.terminal_version
      .. '" terminal_authority="reconcile:v1" action="drop"'
      .. ' terminal_cause="no-semantic-progress" dwell_minutes="' .. tostring(fact.dwell_minutes)
      .. '" decompose_check="no-proposal-pr-delegation-or-terminal-lineage-decomposed"'
      .. ' operator_handling_check="no-post-terminal-human-comment" -->'
  end
  return '<!-- fkst:github-devloop-ops:terminal-retirement-receipt:v1 proposal="'
    .. fact.proposal_id
    .. '" terminal_state="declined" terminal_version="' .. fact.terminal_version
    .. '" -->'
end

local function retirement_receipt_visible(comments, fact)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(retirement_receipt_pattern) do
      if marker_shared.marker_attr(marker, "proposal") == fact.proposal_id
        and marker_shared.marker_attr(marker, "terminal_state") == fact.terminal_state
        and marker_shared.marker_attr(marker, "terminal_version") == fact.terminal_version then
        if fact.terminal_authority ~= "reconcile:v1" then
          return true
        end
        if marker_shared.marker_attr(marker, "terminal_authority") == "reconcile:v1"
          and marker_shared.marker_attr(marker, "action") == "drop"
          and marker_shared.marker_attr(marker, "terminal_cause") == "no-semantic-progress"
          and marker_shared.marker_attr(marker, "dwell_minutes") == tostring(fact.dwell_minutes)
          and marker_shared.marker_attr(marker, "decompose_check")
            == "no-proposal-pr-delegation-or-terminal-lineage-decomposed"
          and marker_shared.marker_attr(marker, "operator_handling_check") == "no-post-terminal-human-comment" then
          return true
        end
      end
    end
  end
  return false
end

local function retirement_receipt_request(repo, issue_number, fact)
  local source_ref = base_ids.issue_source_ref(repo, issue_number)
  local body
  if fact.terminal_authority == "reconcile:v1" then
    body = table.concat({
      "github-devloop terminal retirement: reconcile drop",
      "",
      "Terminal state: `blocked`",
      "Terminal authority: `reconcile:v1`",
      "Reconcile action: `drop`",
      "Terminal cause: `no-semantic-progress`",
      "Proposal: `" .. fact.proposal_id .. "`",
      "Terminal marker version: `" .. fact.terminal_version .. "`",
      "Required dwell: `" .. tostring(fact.dwell_minutes) .. " minutes`",
      "Elapsed dwell: `" .. tostring(fact.elapsed_minutes) .. " minutes`",
      "Decompose check: `no trusted pr-delegation for this proposal; no decomposed:v1 for this terminal version lineage`",
      "Operator-handling check: `no non-bot comment after the reconcile terminal comment`",
      "",
      retirement_receipt_marker(fact),
      request_shared.ai_sentinel,
    }, "\n")
  else
    body = table.concat({
      "github-devloop terminal retirement: declined",
      "",
      "Terminal state: `declined`",
      "Terminal marker version: `" .. fact.terminal_version .. "`",
      "Decline reason: `" .. fact.decline_reason .. "`",
      "Elapsed dwell: `" .. tostring(fact.elapsed_minutes) .. " minutes`",
      "",
      "The re-adjudication path is reopening with a corrected premise or new evidence.",
      "",
      retirement_receipt_marker(fact),
      request_shared.ai_sentinel,
    }, "\n")
  end
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
    body = body,
    dedup_key = base_ids.dedup_key({
      "terminal-retirement",
      fact.terminal_state,
      fact.proposal_id,
      fact.terminal_version,
    }),
    source_ref = source_ref,
  }
end

local function retirement_dwell(marker_index, marker_created_at, now_seconds)
  local marker_seconds = contract_time.iso_timestamp_epoch_seconds(marker_created_at)
  local current_seconds = tonumber(now_seconds)
  if marker_seconds == nil or current_seconds == nil or current_seconds < marker_seconds then
    return nil, ineligible("terminal-clock-invalid")
  end
  local elapsed_minutes = math.floor((current_seconds - marker_seconds) / 60)
  if elapsed_minutes < common.terminal_retirement_dwell_minutes then
    return nil, ineligible("retirement-dwell-active", elapsed_minutes)
  end
  return {
    marker_index = marker_index,
    elapsed_minutes = elapsed_minutes,
  }
end

local function declined_retirement_fact(issue, proposal_id, terminal_version, now_seconds)
  local marker_index, marker_created_at = declined_terminal_marker_position(
    issue.comments,
    proposal_id,
    terminal_version
  )
  local dwell, failure = retirement_dwell(marker_index, marker_created_at, now_seconds)
  if dwell == nil then
    return nil, failure
  end
  local decline_reason = recorded_decline_reason(issue.comments, proposal_id, terminal_version)
  if decline_reason == nil then
    return nil, ineligible("decline-reason-missing", dwell.elapsed_minutes)
  end
  if has_post_terminal_non_bot_comment(issue.comments, dwell.marker_index) then
    return nil, ineligible("post-terminal-non-bot-comment", dwell.elapsed_minutes)
  end
  return {
    proposal_id = proposal_id,
    terminal_state = "declined",
    terminal_version = terminal_version,
    decline_reason = decline_reason,
    elapsed_minutes = dwell.elapsed_minutes,
  }
end

local function reconcile_drop_retirement_fact(issue, proposal_id, terminal_version, now_seconds)
  local reconcile_fact = conv_reconcile.reconcile_fact_for_terminal_version(
    issue.comments,
    proposal_id,
    terminal_version
  )
  if reconcile_fact == nil then
    return nil, ineligible("reconcile-terminal-fact-missing")
  end
  if reconcile_fact.action ~= "drop" then
    return nil, ineligible("reconcile-terminal-action-unsupported")
  end
  if reconcile_fact.terminal_cause ~= "no-semantic-progress" then
    return nil, ineligible("reconcile-terminal-cause-unsupported")
  end
  local dwell, failure = retirement_dwell(
    reconcile_fact.comment_index,
    reconcile_fact.comment_created_at,
    now_seconds
  )
  if dwell == nil then
    return nil, failure
  end
  if marker_facts.pr_delegation_fact(issue.comments, proposal_id) ~= nil then
    return nil, ineligible("reconcile-terminal-pr-delegation-present", dwell.elapsed_minutes)
  end
  if decompose.decomposed_fact(issue.comments, proposal_id, terminal_version) ~= nil then
    return nil, ineligible("reconcile-terminal-decomposed-present", dwell.elapsed_minutes)
  end
  if has_post_terminal_non_bot_comment(issue.comments, dwell.marker_index) then
    return nil, ineligible("post-terminal-non-bot-comment", dwell.elapsed_minutes)
  end
  return {
    proposal_id = proposal_id,
    terminal_state = "blocked",
    terminal_version = terminal_version,
    terminal_authority = "reconcile:v1",
    reconcile_action = reconcile_fact.action,
    terminal_cause = reconcile_fact.terminal_cause,
    dwell_minutes = common.terminal_retirement_dwell_minutes,
    elapsed_minutes = dwell.elapsed_minutes,
  }
end

local function observed_reconcile_drop_candidate(entity)
  local observed_state = type(entity) == "table" and entity.state or nil
  local observed_issue = type(entity) == "table" and entity.parent_issue or nil
  local fact = conv_reconcile.reconcile_fact_for_terminal_version(
    observed_issue and observed_issue.comments,
    entity and entity.proposal_id,
    observed_state and observed_state.version
  )
  return fact ~= nil
    and fact.action == "drop"
    and fact.terminal_cause == "no-semantic-progress"
end

local terminal_retirement_kinds = {
  declined = {
    derive_fact = declined_retirement_fact,
    observed_candidate = function() return true end,
  },
  blocked = {
    derive_fact = reconcile_drop_retirement_fact,
    observed_candidate = observed_reconcile_drop_candidate,
  },
}

function M.decide(issue, expected, now_seconds)
  if type(issue) ~= "table" then
    return ineligible("issue-missing")
  end
  if tostring(issue.state or ""):upper() ~= "OPEN" then
    return ineligible("issue-not-open")
  end
  local expected_state = type(expected) == "table" and expected.state or nil
  local retirement_kind = terminal_retirement_kinds[expected_state]
  if retirement_kind == nil then
    return ineligible("not-declined")
  end
  local proposal_id = exact_marker_value(expected.proposal_id, base_ids.max_key_len)
  local terminal_version = exact_marker_value(expected.version, base_ids.max_dedup_len)
  if proposal_id == nil or terminal_version == nil then
    return ineligible("terminal-identity-invalid")
  end
  if not devloop_state.is_current_state(issue.comments, proposal_id, expected_state, terminal_version) then
    return ineligible("terminal-changed")
  end

  local fact, failure = retirement_kind.derive_fact(issue, proposal_id, terminal_version, now_seconds)
  if fact == nil then
    return failure
  end
  if retirement_receipt_visible(issue.comments, fact) then
    return {
      decision = "eligible",
      action = "close",
      fact = fact,
    }
  end
  return {
    decision = "eligible",
    action = "receipt",
    fact = fact,
    request = retirement_receipt_request(expected.repo, expected.issue_number, fact),
  }
end

local function log_retirement(expected, decision, action, mode, reason)
  log.info(table.concat({
    "github-devloop",
    "dept=observability",
    "tag=TERMINAL_RETIREMENT",
    "proposal=" .. tostring(expected and expected.proposal_id or "unknown"),
    "terminal_state=" .. tostring(expected and expected.state or "unknown"),
    "terminal_version=" .. tostring(expected and expected.version or "unknown"),
    "decision=" .. tostring(decision or "ineligible"),
    "action=" .. tostring(action or "skip"),
    "mode=" .. tostring(mode or "dry-run"),
    "reason=" .. tostring(reason or "none"),
  }, " "))
end

function M.reconcile(github, repo, entity, limits, deadline)
  local observed_state = type(entity) == "table" and entity.state or nil
  local observed_issue = type(entity) == "table" and entity.parent_issue or nil
  local retirement_kind = type(observed_state) == "table"
    and terminal_retirement_kinds[observed_state.state]
    or nil
  if type(observed_state) ~= "table"
    or retirement_kind == nil
    or tostring(observed_issue and observed_issue.state or ""):upper() ~= "OPEN" then
    return nil
  end
  if not retirement_kind.observed_candidate(entity) then
    return nil
  end
  local expected = {
    proposal_id = entity.proposal_id,
    repo = repo,
    issue_number = entity.issue_number,
    state = observed_state.state,
    version = observed_state.version,
  }
  if not sweep_bounds.sweep_has_budget(deadline) then
    log_retirement(expected, "ineligible", "defer", config.write_mode(), "deadline")
    return nil
  end
  if type(github) ~= "table" or type(github.read_issue) ~= "function" then
    error("github-devloop-ops: terminal-retirement-github-port-missing: observability retirement requires a GitHub adapter")
  end

  local fresh_issue = github.read_issue(base_ids.issue_source_ref(repo, entity.issue_number), {
    force_fresh = true,
    timeout = sweep_bounds.sweep_call_timeout(limits, deadline),
    consumer = "github-devloop-ops.terminal-retirement",
  })
  local decision = M.decide(fresh_issue, expected, now())
  local mode = config.write_mode()
  if decision.decision ~= "eligible" then
    log_retirement(expected, decision.decision, "skip", mode, decision.reason)
    return nil
  end
  if mode ~= "real" then
    log_retirement(expected, decision.decision, "would-retire", mode, decision.action)
    return nil
  end
  if decision.action == "receipt" then
    log_retirement(expected, decision.decision, "receipt", mode, "retirement-eligible")
    return {
      queue = "github-proxy.github_issue_comment_request",
      payload = decision.request,
      fact = decision.fact,
    }
  end
  if decision.action ~= "close" then
    error("github-devloop-ops: terminal-retirement-decision-invalid: eligible decision has no supported action")
  end
  if not sweep_bounds.sweep_has_budget(deadline) then
    log_retirement(expected, decision.decision, "defer", mode, "deadline-after-fresh-read")
    return nil
  end
  local timeout = sweep_bounds.sweep_call_timeout(limits, deadline)
  if timeout < 1 then
    log_retirement(expected, decision.decision, "defer", mode, "deadline-after-fresh-read")
    return nil
  end
  local closed = github.issue_close(repo, entity.issue_number, { kind = "not_planned" }, timeout)
  if type(closed) ~= "table" or closed.exit_code ~= 0 then
    error("github-devloop-ops: terminal-retirement-close-failed: issue close failed: "
      .. tostring(closed and closed.stderr or "missing result"))
  end
  entity_view.invalidate_entity_after_write(repo, "issue", entity.issue_number)
  log_retirement(expected, decision.decision, "close", mode, "receipt-visible")
  return nil
end

return M
