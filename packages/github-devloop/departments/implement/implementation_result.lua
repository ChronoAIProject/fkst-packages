local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local impl_failure = require("devloop.impl_failure")
local strings = require("contract.strings")
local implementation_refusal = require("devloop.implementation_refusal")

local json = json
local M = {}

local schema = "github-devloop.implementation-result.v1"
local common_keys = {
  schema = true,
  outcome = true,
  proposal_id = true,
  implementation_version = true,
  attempt = true,
}
local refusal_keys = {
  reason = true,
  evidence = true,
  blocker = true,
}

local function trim(value)
  return strings.trim(value or "")
end

local function validate_keys(value, refusal)
  for key in pairs(value) do
    if common_keys[key] ~= true and (not refusal or refusal_keys[key] ~= true) then
      return nil, "unsupported field " .. tostring(key)
    end
  end
  return true
end

local function exact_field(value, expected, name)
  if expected ~= nil and tostring(value or "") ~= tostring(expected) then
    return nil, name .. " does not match the current implementation attempt"
  end
  return true
end

local function precursor_blocker(value, proposal_id)
  if type(value) ~= "table" then
    return nil
  end
  for key in pairs(value) do
    if key ~= "repo" and key ~= "issue_number" then
      return nil
    end
  end
  if type(value.repo) ~= "string"
    or type(value.issue_number) ~= "number"
    or value.issue_number ~= math.floor(value.issue_number)
    or not base_ids.issue_ref_round_trips(value.repo, value.issue_number) then
    return nil
  end
  local proposal_repo = base_ids.parse_proposal_id(proposal_id)
  if proposal_repo == nil or value.repo ~= proposal_repo then
    return nil
  end
  return {
    repo = value.repo,
    issue_number = value.issue_number,
  }
end

function M.decode(raw, expected)
  local text = trim(raw)
  if text == "" or #text > devloop_base._max_impl_output_len then
    return nil, "typed result envelope is empty or exceeds the implementation receipt bound"
  end
  local ok, value = pcall(json.decode, text)
  if not ok or type(value) ~= "table" then
    return nil, "typed result envelope is not valid JSON"
  end
  if value.schema ~= schema then
    return nil, "schema must be " .. schema
  end
  if value.outcome ~= "changes-produced" and value.outcome ~= "cannot-implement-here" then
    return nil, "outcome must be changes-produced or cannot-implement-here"
  end
  local refusal = value.outcome == "cannot-implement-here"
  local keys_ok, keys_err = validate_keys(value, refusal)
  if not keys_ok then
    return nil, keys_err
  end
  if type(value.attempt) ~= "number" then
    return nil, "attempt must be a positive bounded integer"
  end
  local attempt = impl_failure.valid_attempt(value.attempt)
  if attempt == nil then
    return nil, "attempt must be a positive bounded integer"
  end
  if not strings.is_bounded_string(value.proposal_id, devloop_base._max_key_len)
    or not strings.is_bounded_string(value.implementation_version, devloop_base._max_dedup_len) then
    return nil, "typed result envelope contains an invalid common field"
  end

  expected = expected or {}
  for _, pair in ipairs({
    { "proposal_id", value.proposal_id, expected.proposal_id },
    { "implementation_version", value.implementation_version, expected.implementation_version },
    { "attempt", attempt, expected.attempt },
  }) do
    local matches, err = exact_field(pair[2], pair[3], pair[1])
    if not matches then
      return nil, err
    end
  end

  local receipt = {
    schema = value.schema,
    outcome = value.outcome,
    proposal_id = value.proposal_id,
    implementation_version = value.implementation_version,
    attempt = attempt,
    raw = text,
  }
  if refusal then
    if not implementation_refusal.is_supported_reason(value.reason) then
      return nil, "reason must be one of " .. implementation_refusal.reasons_text()
    end
    if not implementation_refusal.is_valid_evidence(value.evidence) then
      return nil, "evidence must be a non-empty string"
    end
    local blocker = precursor_blocker(value.blocker, value.proposal_id)
    if value.reason == "precursor-missing" and blocker == nil then
      return nil, "precursor-missing requires blocker to be a same-repository IssueRef"
    end
    if value.reason ~= "precursor-missing" and value.blocker ~= nil then
      return nil, "blocker is supported only for precursor-missing"
    end
    receipt.reason = value.reason
    receipt.evidence = value.evidence
    receipt.blocker = blocker
  end
  return receipt, nil
end

return M
