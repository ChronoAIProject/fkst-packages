local metadata = require("devloop.restart_metadata")

local M = {}

local function illegal(reason_code)
  return {
    status = "illegal",
    reason_code = reason_code,
    cas_outcome = "illegal(" .. reason_code .. ")",
    granted_effect_ids = {},
    grant = nil,
  }
end

function M.index(owner, rows)
  local by_state = {}
  for _, row in ipairs(rows or {}) do
    local entitlement = row.receiver_dispatch_effect_entitlement
    if entitlement ~= nil then
      local state = row.from_state
      if type(state) ~= "string" or state == "" or by_state[state] ~= nil then
        error("devloop.restart_receiver_dispatch: receiver-state-identity-invalid: receiver state must be unique and non-empty")
      end
      if type(entitlement.id) ~= "string" or entitlement.id == ""
        or type(entitlement.effect_ids) ~= "table" or #entitlement.effect_ids ~= 1
        or type(entitlement.effect_ids[1]) ~= "string" or entitlement.effect_ids[1] == "" then
        error("devloop.restart_receiver_dispatch: receiver-entitlement-cardinality-invalid: receiver entitlement must name exactly one effect")
      end
      by_state[state] = {
        owner = owner,
        receiver_state = state,
        entitlement = {
          id = entitlement.id,
          effect_ids = metadata.copy_array(entitlement.effect_ids),
        },
      }
    end
  end
  return by_state
end

function M.decide(index, current, intent)
  if type(intent) ~= "table" then return illegal("malformed-receiver-intent") end
  for field in pairs(intent) do
    if field ~= "receiver_state" and field ~= "accepted_handoff" then
      return illegal("malformed-receiver-intent")
    end
  end
  if type(intent.receiver_state) ~= "string" or intent.receiver_state == ""
    or (intent.accepted_handoff ~= nil and type(intent.accepted_handoff) ~= "boolean") then
    return illegal("malformed-receiver-intent")
  end
  local receiver = index[intent.receiver_state]
  if receiver == nil then return illegal("unknown-receiver-state") end

  local status
  local reason_code
  local cas_outcome
  if type(current) == "table" and current.state == receiver.receiver_state then
    status = "idempotent"
    reason_code = "receiver-state-visible"
    cas_outcome = "skip-idempotent(receiver-state-visible)"
  elseif receiver.receiver_state == "implementing" and intent.accepted_handoff == true then
    status = "apply"
    reason_code = "accepted-in-process-handoff"
    cas_outcome = "applied(accepted-in-process-handoff)"
  else
    return illegal("receiver-state-not-admitted")
  end

  return {
    status = status,
    reason_code = reason_code,
    cas_outcome = cas_outcome,
    authority_kind = "receiver-dispatch",
    receiver_dispatch_id = receiver.entitlement.id,
    receiver_state = receiver.receiver_state,
    effect_entitlement_id = receiver.entitlement.id,
    granted_effect_ids = metadata.copy_array(receiver.entitlement.effect_ids),
    grant = nil,
  }
end

return M
