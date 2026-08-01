local devloop_base = require("devloop.base")
local impl_failure = require("devloop.impl_failure")
local strings = require("contract.strings")
local implementation_refusal = require("core.implementation_refusal")

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
    if not strings.is_bounded_string(value.evidence, devloop_base._max_blocking_gap_len)
      or trim(value.evidence) == "" then
      return nil, "evidence must be a non-empty bounded string"
    end
    receipt.reason = value.reason
    receipt.evidence = value.evidence
  end
  return receipt, nil
end

return M
