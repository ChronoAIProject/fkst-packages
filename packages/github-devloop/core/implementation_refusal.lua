local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local impl_failure = require("devloop.impl_failure")
local marker_shared = require("devloop.markers.shared")
local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")

local M = {}

function M.marker(proposal_id, implementation_version, reason, evidence, attempt)
  local n = impl_failure.valid_attempt(attempt)
  if not strings.is_path_safe_key(proposal_id, devloop_base._max_key_len)
    or not strings.is_bounded_string(implementation_version, devloop_base._max_dedup_len)
    or reason ~= "precursor-missing"
    or n == nil
    or not strings.is_bounded_string(evidence, devloop_base._max_blocking_gap_len)
    or strings.trim(evidence) == "" then
    error("github-devloop: invalid-implementation-refusal-marker: invalid implementation refusal marker")
  end
  return '<!-- fkst:github-devloop:implementation-refusal:v1 proposal="' .. proposal_id
    .. '" reason="' .. reason
    .. '" attempt="' .. tostring(n)
    .. '" dedup="' .. implementation_version
    .. '" evidence="' .. marker_shared.encode_exact_marker_attr(evidence)
    .. '" -->'
end

local function fact_from_marker(marker, comment, proposal_id, implementation_version)
  local marker_proposal = marker_shared.marker_attr(marker, "proposal")
  local marker_version = marker_shared.marker_attr(marker, "dedup")
  local reason = marker_shared.marker_attr(marker, "reason")
  local attempt = impl_failure.valid_attempt(marker_shared.marker_attr(marker, "attempt"))
  local evidence = marker_shared.decode_exact_marker_attr(marker_shared.marker_attr(marker, "evidence"))
  if marker_proposal ~= tostring(proposal_id)
    or marker_version ~= tostring(implementation_version)
    or reason ~= "precursor-missing"
    or attempt == nil
    or not strings.is_bounded_string(marker_version, devloop_base._max_dedup_len)
    or not strings.is_bounded_string(evidence, devloop_base._max_blocking_gap_len)
    or strings.trim(evidence) == "" then
    return nil
  end
  if marker ~= M.marker(marker_proposal, marker_version, reason, evidence, attempt) then
    return nil
  end
  return {
    proposal_id = marker_proposal,
    implementation_version = marker_version,
    reason = reason,
    evidence = evidence,
    attempt = attempt,
    comment_created_at = parsers_misc._comment_created_at(comment),
  }
end

function M.fact(comments, proposal_id, implementation_version)
  if type(comments) ~= "table"
    or not devloop_state.is_current_state(
      comments, proposal_id, "blocked", implementation_version) then
    return nil
  end
  local best = nil
  local marker_pattern = "<!%-%- fkst:github%-devloop:implementation%-refusal:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local candidate = fact_from_marker(
        marker, comment, proposal_id, implementation_version)
      if candidate ~= nil and (best == nil or candidate.attempt > best.attempt) then
        best = candidate
      end
    end
  end
  return best
end

function M.install(core)
  core.implementation_refusal_marker = M.marker
  core.implementation_refusal_fact = M.fact
end

return M
