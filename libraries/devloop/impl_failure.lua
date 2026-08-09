local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")
local devloop_state = require("devloop.state")
local transition_version = require("contract.transition_version")

local M = {}

M.MAX_AUTO_RETRY_ATTEMPTS = 2
M.MAX_RETRY_ATTEMPTS = 100000

local legacy_v1_retryable_reasons = {
  ["codex-failed"] = true,
  ["lean-proof-repair-needed"] = true,
  ["non-descendant-head"] = true,
}

local valid_fault_classes = {
  SEMANTIC = true,
  CONFIGURATION = true,
  TOOLCHAIN = true,
  INFRASTRUCTURE = true,
  UNKNOWN = true,
}

local function marker_attr(marker, name)
  return marker:match(name .. '="([^"]*)"')
end

function M.valid_attempt(value)
  local n = tonumber(value)
  if n == nil or n < 1 or n ~= math.floor(n) or n > M.MAX_RETRY_ATTEMPTS then
    return nil
  end
  return n
end

local function valid_fault_class(value)
  if type(value) ~= "string" or valid_fault_classes[value] ~= true then
    return nil
  end
  return value
end

local function retryable_attr(value)
  if value == "true" then
    return true
  end
  if value == "false" then
    return false
  end
  return nil
end

local function fact_from_marker(max_key_len, max_dedup_len, marker, comment, proposal_id, dedup_key)
  local marker_proposal = marker_attr(marker, "proposal")
  local marker_dedup = marker_attr(marker, "dedup")
  local reason = marker_attr(marker, "reason")
  local raw_fault_class = marker_attr(marker, "fault_class")
  local raw_retryable = marker_attr(marker, "retryable")
  local legacy_v1 = raw_fault_class == nil and raw_retryable == nil
  local fault_class = legacy_v1 and nil or valid_fault_class(raw_fault_class)
  local retryable
  if legacy_v1 then
    retryable = legacy_v1_retryable_reasons[reason] == true
  else
    retryable = retryable_attr(raw_retryable)
  end
  if marker_proposal ~= tostring(proposal_id)
    or (dedup_key ~= nil and marker_dedup ~= tostring(dedup_key))
    or reason == nil
    or (not legacy_v1 and (fault_class == nil or retryable == nil))
    or not strings.is_bounded_string(reason, max_key_len)
    or (max_dedup_len ~= nil and not strings.is_bounded_string(marker_dedup, max_dedup_len)) then
    return nil
  end
  return {
    proposal_id = marker_proposal,
    dedup_key = marker_dedup,
    reason = reason,
    fault_class = fault_class,
    retryable = retryable,
    attempt = M.valid_attempt(marker_attr(marker, "attempt")) or 1,
    comment_created_at = parsers_misc._comment_created_at(comment),
  }
end

local function find_fact(max_key_len, max_dedup_len, comments, proposal_id, dedup_key, current_only)
  if type(comments) ~= "table" then
    return nil
  end
  local best = nil
  local marker_pattern = "<!%-%- fkst:github%-devloop:impl%-failure:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local candidate = fact_from_marker(max_key_len, max_dedup_len, marker, comment, proposal_id, dedup_key)
      local is_current = candidate ~= nil and (not current_only or devloop_state.is_current_state(
        comments,
        proposal_id,
        "impl-failed",
        candidate.dedup_key
      ))
      if is_current and (best == nil or candidate.attempt > best.attempt) then
        best = candidate
      end
    end
  end
  return best
end

function M.fact(max_key_len, comments, proposal_id, dedup_key)
  return find_fact(max_key_len, nil, comments, proposal_id, dedup_key, false)
end

function M.current_fact(max_key_len, max_dedup_len, comments, proposal_id)
  return find_fact(max_key_len, max_dedup_len, comments, proposal_id, nil, true)
end

function M.retry_allowed(fact)
  local attempt = type(fact) == "table" and M.valid_attempt(fact.attempt or 1) or nil
  return attempt ~= nil
    and fact.retryable == true
    and attempt < M.MAX_AUTO_RETRY_ATTEMPTS
end

function M.implementation_base_version(version)
  return transition_version.strip_trailing_reimplement(version)
end

function M.implementation_branch_version(version, attempt)
  local replacement_round = transition_version.trailing_reimplement_round(version)
  local retry_attempt = attempt == nil and nil or M.valid_attempt(attempt)
  if attempt ~= nil and retry_attempt == nil then
    error("github-devloop: invalid-attempt: invalid implementation branch attempt")
  end
  if replacement_round == 1 and (retry_attempt == nil or retry_attempt == replacement_round) then
    return tostring(version or "")
  end
  if replacement_round ~= 0
    and retry_attempt ~= nil
    and replacement_round ~= retry_attempt
    and replacement_round + 1 ~= retry_attempt
  then
    error("github-devloop: invalid-version-lineage: implementation retry suffix does not match structured attempt")
  end
  return M.implementation_base_version(version)
end

function M.implementation_attempt_version(version, attempt)
  local n = attempt == nil and nil or M.valid_attempt(attempt)
  if attempt ~= nil and n == nil then
    error("github-devloop: invalid-attempt: invalid implementation attempt version")
  end
  if transition_version.trailing_reimplement_round(
    M.implementation_branch_version(version, n)
  ) == 1 then
    return tostring(version or "")
  end
  local base = M.implementation_base_version(version)
  if n == nil or n <= 1 then
    return base
  end
  return transition_version.reimplement_at(base, n)
end

return {
  MAX_AUTO_RETRY_ATTEMPTS = M.MAX_AUTO_RETRY_ATTEMPTS,
  MAX_RETRY_ATTEMPTS = M.MAX_RETRY_ATTEMPTS,
  valid_attempt = M.valid_attempt,
  valid_fault_class = valid_fault_class,
  fact = M.fact,
  current_fact = M.current_fact,
  retry_allowed = M.retry_allowed,
  implementation_base_version = M.implementation_base_version,
  implementation_branch_version = M.implementation_branch_version,
  implementation_attempt_version = M.implementation_attempt_version,
}
