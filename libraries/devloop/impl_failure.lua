local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")
local devloop_state = require("devloop.state")
local transition_version = require("contract.transition_version")

local M = {}

M.MAX_AUTO_RETRY_ATTEMPTS = 2
M.MAX_RETRY_ATTEMPTS = 100000

local auto_retryable_reasons = {
  ["codex-failed"] = true,
  ["lean-proof-repair-needed"] = true,
  ["non-descendant-head"] = true,
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

local function fact_from_marker(max_key_len, max_dedup_len, marker, comment, proposal_id, dedup_key)
  local marker_proposal = marker_attr(marker, "proposal")
  local marker_dedup = marker_attr(marker, "dedup")
  local reason = marker_attr(marker, "reason")
  if marker_proposal ~= tostring(proposal_id)
    or (dedup_key ~= nil and marker_dedup ~= tostring(dedup_key))
    or reason == nil
    or not strings.is_bounded_string(reason, max_key_len)
    or (max_dedup_len ~= nil and not strings.is_bounded_string(marker_dedup, max_dedup_len)) then
    return nil
  end
  return {
    proposal_id = marker_proposal,
    dedup_key = marker_dedup,
    reason = reason,
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
  return type(fact) == "table"
    and auto_retryable_reasons[fact.reason] == true
    and tonumber(fact.attempt or 1) < M.MAX_AUTO_RETRY_ATTEMPTS
end

function M.next_retry_attempt(fact)
  if not M.retry_allowed(fact) then
    return nil
  end
  return tonumber(fact.attempt or 1) + 1
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

return M
