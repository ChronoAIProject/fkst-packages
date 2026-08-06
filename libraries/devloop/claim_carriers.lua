local devloop_base = require("devloop.base")

local C = {}

C.bare_label = "fkst-dev:claimed"

local max_label_length = 50

function C.derived_label(owner)
  local label = C.bare_label .. ":" .. owner
  if #label > max_label_length then
    error("devloop.claim_carriers: claim-label-too-long: derived claim label exceeds 50 characters")
  end
  return label
end

function C.active_label(exclusive, owner)
  if exclusive == true then
    return C.bare_label
  end
  return C.derived_label(owner)
end

function C.is_claim_family(name)
  if name == C.bare_label then
    return true
  end
  if type(name) ~= "string" then
    return false
  end
  local prefix = C.bare_label .. ":"
  return name:sub(1, #prefix) == prefix and #name > #prefix
end

function C.classify_labels(labels, active)
  local active_present = false
  for _, name in ipairs(type(labels) == "table" and labels or {}) do
    if C.is_claim_family(name) then
      if name ~= active then
        return "other"
      end
      active_present = true
    end
  end
  if active_present then
    return "self"
  end
  return "unassigned"
end

function C.classify(mode, assignees, owner, labels, active_label, managed)
  local label_state = C.classify_labels(labels, mode == "label" and active_label or nil)
  if label_state == "other" then
    return "other"
  end

  local normalized_owner = devloop_base.strip_bot_login_suffix(owner)
  if mode == "label" then
    for _, login in ipairs(type(assignees) == "table" and assignees or {}) do
      local normalized = devloop_base.strip_bot_login_suffix(login)
      if type(managed) == "table" and managed[normalized] == true and normalized ~= normalized_owner then
        return "other"
      end
    end
    return label_state
  end

  local logins = type(assignees) == "table" and assignees or {}
  if #logins == 0 then
    return "unassigned"
  end
  if #logins == 1 and devloop_base.strip_bot_login_suffix(logins[1]) == normalized_owner then
    return "self"
  end
  return "other"
end

return C
