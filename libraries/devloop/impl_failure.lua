local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")
local devloop_state = require("devloop.state")

local M = {}

M.MAX_AUTO_RETRY_ATTEMPTS = 2
M.MAX_RETRY_ATTEMPTS = 100000

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

function M.valid_fault_class(value)
  if type(value) ~= "string" or valid_fault_classes[value] ~= true then
    return nil
  end
  return value
end

local function fact_from_marker(max_key_len, max_dedup_len, marker, comment, proposal_id, dedup_key)
  local marker_proposal = marker_attr(marker, "proposal")
  local marker_dedup = marker_attr(marker, "dedup")
  local reason = marker_attr(marker, "reason")
  local fault_class = M.valid_fault_class(marker_attr(marker, "fault_class"))
  if marker_proposal ~= tostring(proposal_id)
    or (dedup_key ~= nil and marker_dedup ~= tostring(dedup_key))
    or reason == nil
    or fault_class == nil
    or not strings.is_bounded_string(reason, max_key_len)
    or (max_dedup_len ~= nil and not strings.is_bounded_string(marker_dedup, max_dedup_len)) then
    return nil
  end
  return {
    proposal_id = marker_proposal,
    dedup_key = marker_dedup,
    reason = reason,
    fault_class = fault_class,
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
    and fact.fault_class == "INFRASTRUCTURE"
    and attempt < M.MAX_AUTO_RETRY_ATTEMPTS
end

function M.next_retry_attempt(fact)
  if not M.retry_allowed(fact) then
    return nil
  end
  return M.valid_attempt(fact.attempt or 1) + 1
end

return M
