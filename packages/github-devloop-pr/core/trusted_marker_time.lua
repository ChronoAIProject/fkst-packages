local contract_time = require("contract.time")
local transition_version = require("contract.transition_version")

local C = {}

local function policy_invalid(reason)
  return {
    status = "policy-invalid",
    reason = reason,
  }
end

function C.parse(value)
  local parsed = contract_time.iso_timestamp_epoch_seconds(value)
  if parsed == nil then
    return policy_invalid("trusted marker timestamp is unparseable")
  end
  return {
    status = "valid",
    seconds = parsed,
  }
end

function C.state_entry(state)
  local lineage = C.parse(transition_version.updated_at(state and state.version))
  if lineage.status == "policy-invalid" then
    return policy_invalid("version lineage timestamp is unparseable")
  end
  local marker_created_at = state and state.marker_created_at
  if marker_created_at == nil or marker_created_at == "" then
    lineage.source = "version-lineage"
    return lineage
  end
  local parsed_marker = C.parse(marker_created_at)
  if parsed_marker.status == "valid" then
    parsed_marker.seconds = math.max(lineage.seconds, parsed_marker.seconds)
  end
  parsed_marker.source = "state-marker"
  return parsed_marker
end

function C.marker_after_state_entry(value, state_entry)
  if type(state_entry) ~= "table" or state_entry.status ~= "valid" then
    return policy_invalid("trusted marker time requires a valid state entry")
  end
  local parsed = C.parse(value)
  if parsed.status == "valid" then
    parsed.seconds = math.max(state_entry.seconds, parsed.seconds)
  end
  return parsed
end

return C
