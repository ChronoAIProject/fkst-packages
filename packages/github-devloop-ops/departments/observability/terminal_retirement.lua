local base_ids = require("devloop.base_ids")
local common = require("departments.observability.common")
local config = require("devloop.config")
local contract_time = require("contract.time")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local entity_view = require("devloop.github_proxy_entity_view")
local marker_shared = require("devloop.markers.shared")
local parsers_misc = require("devloop.parsers.misc")
local request_shared = require("devloop.requests.shared")
local sweep_bounds = require("devloop.sweep_bounds")

local M = {}

local retirement_receipt_pattern = "<!%-%- fkst:github%-devloop%-ops:terminal%-retirement%-receipt:v1.-%-%->"
local result_marker_pattern = "<!%-%- fkst:github%-devloop:result:v1.-%-%->"
local state_marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"

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

local function terminal_marker_created_at(comments, proposal_id, terminal_version)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(state_marker_pattern) do
      if marker_shared.marker_attr(marker, "proposal") == proposal_id
        and marker_shared.marker_attr(marker, "state") == "declined"
        and marker_shared.marker_attr(marker, "version") == terminal_version then
        return parsers_misc._comment_created_at(comment)
      end
    end
  end
  return nil
end

local function has_later_state_marker(comments, proposal_id, terminal_marker_seconds)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    local created_seconds = contract_time.iso_timestamp_epoch_seconds(
      parsers_misc._comment_created_at(comment)
    )
    for marker in parsers_misc._comment_body(comment):gmatch(state_marker_pattern) do
      if marker_shared.marker_attr(marker, "proposal") == proposal_id
        and (created_seconds == nil or created_seconds > terminal_marker_seconds) then
        return true
      end
    end
  end
  return false
end

local function has_post_terminal_non_bot_comment(comments, marker_seconds)
  local trusted_bot = devloop_base.strip_bot_login_suffix(devloop_base.trusted_bot_login())
  for _, comment in ipairs(comments or {}) do
    local author = devloop_base.strip_bot_login_suffix(parsers_misc._comment_author_login(comment))
    if author ~= trusted_bot then
      local created_seconds = contract_time.iso_timestamp_epoch_seconds(
        parsers_misc._comment_created_at(comment)
      )
      if created_seconds == nil or created_seconds > marker_seconds then
        return true
      end
    end
  end
  return false
end

local function retirement_receipt_marker(fact)
  return '<!-- fkst:github-devloop-ops:terminal-retirement-receipt:v1 proposal="'
    .. fact.proposal_id
    .. '" terminal_state="declined" terminal_version="' .. fact.terminal_version
    .. '" -->'
end

local function retirement_receipt_visible(comments, fact)
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(retirement_receipt_pattern) do
      if marker_shared.marker_attr(marker, "proposal") == fact.proposal_id
        and marker_shared.marker_attr(marker, "terminal_state") == "declined"
        and marker_shared.marker_attr(marker, "terminal_version") == fact.terminal_version then
        return true
      end
    end
  end
  return false
end

local function retirement_receipt_request(repo, issue_number, fact)
  local source_ref = base_ids.issue_source_ref(repo, issue_number)
  return {
    schema = "github-proxy.v1",
    repo = repo,
    issue_number = issue_number,
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
    }, "\n"),
    dedup_key = base_ids.dedup_key({
      "terminal-retirement",
      "declined",
      fact.proposal_id,
      fact.terminal_version,
    }),
    source_ref = source_ref,
  }
end

function M.decide(issue, expected, now_seconds)
  if type(issue) ~= "table" then
    return ineligible("issue-missing")
  end
  if tostring(issue.state or ""):upper() ~= "OPEN" then
    return ineligible("issue-not-open")
  end
  if type(expected) ~= "table" or expected.state ~= "declined" then
    return ineligible("not-declined")
  end
  local proposal_id = exact_marker_value(expected.proposal_id, base_ids.max_key_len)
  local terminal_version = exact_marker_value(expected.version, base_ids.max_dedup_len)
  if proposal_id == nil or terminal_version == nil then
    return ineligible("terminal-identity-invalid")
  end

  if not devloop_state.is_current_state(issue.comments, proposal_id, "declined", terminal_version) then
    return ineligible("terminal-changed")
  end
  local marker_created_at = terminal_marker_created_at(issue.comments, proposal_id, terminal_version)
  local marker_seconds = contract_time.iso_timestamp_epoch_seconds(marker_created_at)
  local current_seconds = tonumber(now_seconds)
  if marker_seconds == nil or current_seconds == nil or current_seconds < marker_seconds then
    return ineligible("terminal-clock-invalid")
  end
  if has_later_state_marker(issue.comments, proposal_id, marker_seconds) then
    return ineligible("terminal-changed")
  end
  local elapsed_minutes = math.floor((current_seconds - marker_seconds) / 60)
  if elapsed_minutes < common.terminal_retirement_dwell_minutes.declined then
    return ineligible("retirement-dwell-active", elapsed_minutes)
  end
  local decline_reason = recorded_decline_reason(issue.comments, proposal_id, terminal_version)
  if decline_reason == nil then
    return ineligible("decline-reason-missing", elapsed_minutes)
  end
  if has_post_terminal_non_bot_comment(issue.comments, marker_seconds) then
    return ineligible("post-terminal-non-bot-comment", elapsed_minutes)
  end

  local fact = {
    proposal_id = proposal_id,
    terminal_state = "declined",
    terminal_version = terminal_version,
    decline_reason = decline_reason,
    elapsed_minutes = elapsed_minutes,
  }
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
    "terminal_state=declined",
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
  if type(observed_state) ~= "table"
    or observed_state.state ~= "declined"
    or tostring(observed_issue and observed_issue.state or ""):upper() ~= "OPEN" then
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
