local devloop_base = require("devloop.base")
local sha256 = require("contract.sha256")

local C = {}

C.bare_label = "fkst-dev:claimed"

local claim_description = "fkst-dev-label-mode-ownership-claim"
-- A 128-bit SHA-256 prefix keeps the complete label at 49 characters.
local owner_digest_hex_length = 32

local function canonical_owner(owner)
  local canonical = devloop_base.strip_bot_login_suffix(owner)
  if canonical == nil or canonical == "" then
    error("devloop.claim_carriers: claim-owner-missing: claim owner must be non-empty")
  end
  return canonical
end

function C.derived_label(owner)
  local digest = sha256.hex(canonical_owner(owner))
  return C.bare_label .. ":" .. digest:sub(1, owner_digest_hex_length)
end

function C.active_label_spec(exclusive, owner)
  if exclusive == true then
    return {
      name = C.bare_label,
      description = claim_description,
    }
  end
  local canonical = canonical_owner(owner)
  return {
    name = C.derived_label(canonical),
    description = claim_description .. " owner=" .. canonical,
    owner = canonical,
  }
end

function C.assert_owner_binding(existing, desired)
  if existing == nil or desired.owner == nil or tostring(existing.name or "") ~= desired.name then
    return
  end
  if tostring(existing.description or "") ~= desired.description then
    error("devloop.claim_carriers: claim-label-owner-collision: derived claim label is bound to another owner")
  end
end

function C.active_label(exclusive, owner)
  return C.active_label_spec(exclusive, owner).name
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
  local normalized_owner = devloop_base.strip_bot_login_suffix(owner)
  if #assignees == 0 then
    return "unassigned"
  end
  if #assignees == 1 and devloop_base.strip_bot_login_suffix(assignees[1]) == normalized_owner then
    return "self"
  end
  return "other"
end

local function is_managed_login(managed, login)
  for candidate, allowed in pairs(type(managed) == "table" and managed or {}) do
    if allowed == true and devloop_base.strip_bot_login_suffix(candidate) == login then
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

  local normalized_owner = devloop_base.strip_bot_login_suffix(owner)
  if mode == "label" then
    for _, login in ipairs(assignees) do
      local normalized = devloop_base.strip_bot_login_suffix(login)
      if is_managed_login(managed, normalized) and normalized ~= normalized_owner then
        return "other"
      end
    end
    return label_state
  end

  return C.classify_assignees(assignees, normalized_owner)
end

return C
