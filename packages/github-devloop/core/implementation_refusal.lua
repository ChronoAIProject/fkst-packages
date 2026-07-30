local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local impl_failure = require("devloop.impl_failure")
local marker_shared = require("devloop.markers.shared")
local parsers_misc = require("devloop.parsers.misc")
local strings = require("contract.strings")

local M = {}

local reason_specs = {
  {
    reason = "precursor-missing",
    condition = "a required precursor is missing",
  },
  {
    reason = "wrong-layer",
    condition = "the requested change belongs in another repository or architectural layer",
  },
  {
    reason = "already-satisfied",
    condition = "repository ground truth already satisfies the request without new changes",
  },
}
local supported_reason_set = {}
for _, spec in ipairs(reason_specs) do
  supported_reason_set[spec.reason] = true
end

function M.reasons()
  local reasons = {}
  for _, spec in ipairs(reason_specs) do
    table.insert(reasons, spec.reason)
  end
  return reasons
end

function M.is_supported_reason(reason)
  return supported_reason_set[reason] == true
end

function M.reasons_text()
  return table.concat(M.reasons(), ", ")
end

function M.require_supported_reason(reason)
  if not M.is_supported_reason(reason) then
    error("github-devloop: invalid-implementation-refusal-reason: reason must be one of "
      .. M.reasons_text())
  end
  return reason
end

function M.prompt_contract()
  local lines = {
    '- Use `outcome="cannot-implement-here"` only for one of these exact worker-reported reasons:',
  }
  for _, spec in ipairs(reason_specs) do
    table.insert(lines, "  - `" .. spec.reason .. "`: " .. spec.condition .. ".")
  end
  table.insert(lines,
    '- Every `cannot-implement-here` result must also include exactly `reason` and a non-empty bounded `evidence` string. The evidence reports the worker\'s basis; it is not independently verified by the receipt.')
  table.insert(lines,
    '- Do not use `cannot-implement-here` for any other reason and do not add unsupported fields.')
  return table.concat(lines, "\n")
end

function M.marker(proposal_id, implementation_version, reason, evidence, attempt)
  local n = impl_failure.valid_attempt(attempt)
  if not strings.is_path_safe_key(proposal_id, devloop_base._max_key_len)
    or not strings.is_bounded_string(implementation_version, devloop_base._max_dedup_len)
    or not M.is_supported_reason(reason)
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

local function fact_from_marker(marker, comment, proposal_id, implementation_version, expected_attempt)
  local marker_proposal = marker_shared.marker_attr(marker, "proposal")
  local marker_version = marker_shared.marker_attr(marker, "dedup")
  local reason = marker_shared.marker_attr(marker, "reason")
  local attempt = impl_failure.valid_attempt(marker_shared.marker_attr(marker, "attempt"))
  local evidence = marker_shared.decode_exact_marker_attr(marker_shared.marker_attr(marker, "evidence"))
  if marker_proposal ~= tostring(proposal_id)
    or marker_version ~= tostring(implementation_version)
    or not M.is_supported_reason(reason)
    or attempt == nil
    or attempt ~= expected_attempt
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

function M.fact(comments, proposal_id, implementation_version, implement_attempt_fact)
  local expected_attempt = type(implement_attempt_fact) == "table"
    and impl_failure.valid_attempt(implement_attempt_fact.attempt)
    or nil
  if type(comments) ~= "table"
    or expected_attempt == nil
    or not devloop_state.is_current_state(
      comments, proposal_id, "blocked", implementation_version) then
    return nil
  end
  local best = nil
  local marker_pattern = "<!%-%- fkst:github%-devloop:implementation%-refusal:v1.-%-%->"
  for _, comment in ipairs(parsers_misc._trusted_marker_comments(comments)) do
    for marker in parsers_misc._comment_body(comment):gmatch(marker_pattern) do
      local candidate = fact_from_marker(
        marker, comment, proposal_id, implementation_version, expected_attempt)
      if candidate ~= nil and (best == nil or candidate.attempt > best.attempt) then
        best = candidate
      end
    end
  end
  return best
end

function M.install(core)
  core.implementation_refusal_reasons = M.reasons
  core.implementation_refusal_reasons_text = M.reasons_text
  core.is_supported_implementation_refusal_reason = M.is_supported_reason
  core.require_supported_implementation_refusal_reason = M.require_supported_reason
  core.implementation_refusal_marker = M.marker
  core.implementation_refusal_fact = function(comments, proposal_id, implementation_version)
    local attempt_fact = core.latest_implement_attempt_fact(
      comments, proposal_id, implementation_version)
    return M.fact(comments, proposal_id, implementation_version, attempt_fact)
  end
end

return M
