local C = {}

C.bare_label = "fkst-dev:claimed"

local max_label_length = 50

function C.derived_label(owner)
  local label = C.bare_label .. ":" .. owner
  if #label > max_label_length then
    error("devloop.claim_labels: claim-label-too-long: derived claim label exceeds 50 characters")
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

function C.classify(labels, active)
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

return C
