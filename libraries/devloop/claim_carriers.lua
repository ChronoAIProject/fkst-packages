local github_author_policy = require("devloop.github_author_policy")

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
  if type(labels) ~= "table" then
    return "other"
  end
  local active_present = false
  for _, name in ipairs(labels) do
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

function C.classify_assignees(assignees, owner)
  if type(assignees) ~= "table" then
    return "other"
  end
  local normalized_owner = github_author_policy.canonical_login(owner)
  if #assignees == 0 then
    return "unassigned"
  end
  if #assignees == 1 and github_author_policy.canonical_login(assignees[1]) == normalized_owner then
    return "self"
  end
  return "other"
end

local function is_managed_login(managed, login)
  for candidate, allowed in pairs(type(managed) == "table" and managed or {}) do
    if allowed == true and github_author_policy.canonical_login(candidate) == login then
      return true
    end
  end
  return false
end

function C.classify(mode, assignees, owner, labels, active_label, managed)
  if type(assignees) ~= "table" or type(labels) ~= "table" then
    return "other"
  end
  local label_state = C.classify_labels(labels, mode == "label" and active_label or nil)
  if label_state == "other" then
    return "other"
  end

  local normalized_owner = github_author_policy.canonical_login(owner)
  if mode == "label" then
    for _, login in ipairs(assignees) do
      local normalized = github_author_policy.canonical_login(login)
      if is_managed_login(managed, normalized) and normalized ~= normalized_owner then
        return "other"
      end
    end
    return label_state
  end

  return C.classify_assignees(assignees, normalized_owner)
end

return C
