local parsers_misc = require("devloop.parsers.misc")
local sha256 = require("contract.sha256")
local validators = require("devloop.commands.validators")

local C = {}

C.bare_label = "fkst-dev:claimed"
C.label_contract_schema = "github-devloop.claim-label.v1"

local claim_description = "fkst-dev-label-mode-ownership-claim"

local function canonical_owner(owner)
  local canonical = parsers_misc.canonical_login(owner)
  if canonical == nil or canonical == "" then
    error("devloop.claim_carriers: claim-owner-missing: claim owner must be non-empty")
  end
  return canonical
end

<<<<<<< HEAD
function C.derived_label(owner, owner_digest_hex_length)
=======
local function copy_source_ref(source_ref)
  if type(source_ref) ~= "table"
    or source_ref.kind ~= "external"
    or type(source_ref.ref) ~= "string"
    or source_ref.ref == "" then
    return nil
  end
  return {
    kind = source_ref.kind,
    ref = source_ref.ref,
  }
end

function C.derived_label(owner)
>>>>>>> d8c2d56babf16257706c3641f2b231f6047351b4
  local digest = sha256.hex(canonical_owner(owner))
  return C.bare_label .. ":" .. digest:sub(1, owner_digest_hex_length)
end

function C.active_label_spec(naming, owner, owner_digest_hex_length)
  if type(naming) ~= "table" then
    error("devloop.claim_carriers: claim-label-naming-invalid: claim label naming posture is invalid")
  end
  local name
  local bound_owner
  if naming.kind == "exclusive" then
    name = C.bare_label
  elseif naming.kind == "derived" then
    bound_owner = canonical_owner(owner)
    name = C.derived_label(bound_owner, owner_digest_hex_length)
  elseif naming.kind == "declared_suffix" and type(naming.suffix) == "string" then
    bound_owner = canonical_owner(owner)
    name = C.bare_label .. ":" .. naming.suffix
  else
    error("devloop.claim_carriers: claim-label-naming-invalid: claim label naming posture is invalid")
  end
  if not validators.is_label_name_valid(name) then
    error("devloop.claim_carriers: claim-label-name-invalid: complete claim label name must contain 1 to 50 characters")
  end
  if bound_owner == nil then
    return {
      name = name,
      description = claim_description,
    }
  end
  return {
    name = name,
    description = claim_description .. " owner=" .. bound_owner,
    owner = bound_owner,
  }
end

function C.assert_owner_binding(existing, desired)
  if existing == nil or desired.owner == nil or tostring(existing.name or "") ~= desired.name then
    return
  end
  if tostring(existing.description or "") ~= desired.description then
    error("devloop.claim_carriers: claim-label-owner-collision: claim label is bound to another owner")
  end
end

function C.active_label(naming, owner, owner_digest_hex_length)
  return C.active_label_spec(naming, owner, owner_digest_hex_length).name
end

function C.new_label_contract(naming, owner, source_ref)
  local normalized_owner = canonical_owner(owner)
  local normalized_source_ref = copy_source_ref(source_ref)
  if normalized_source_ref == nil then
    error("devloop.claim_carriers: claim-contract-source-ref-invalid: label claim source_ref must be external")
  end
  return {
    schema = C.label_contract_schema,
    owner = normalized_owner,
    label = C.active_label(naming, normalized_owner),
    source_ref = normalized_source_ref,
  }
end

function C.validate_label_contract(claim, expected)
  if type(claim) ~= "table" or claim.schema ~= C.label_contract_schema then
    return nil, "claim-contract-version-unknown"
  end
  if claim.owner == nil or tostring(claim.owner) == "" then
    return nil, "claim-contract-owner-missing"
  end
  if type(claim.owner) ~= "string" then
    return nil, "claim-contract-owner-invalid"
  end
  local owner = parsers_misc.canonical_login(claim.owner)
  if owner == nil then
    return nil, "claim-contract-owner-invalid"
  end
  if not parsers_misc.is_canonical_login(claim.owner) then
    return nil, "claim-contract-owner-noncanonical"
  end
  local expected_owner = parsers_misc.canonical_login(expected and expected.owner)
  if expected_owner == nil or owner ~= expected_owner then
    return nil, "claim-owner-mismatch"
  end
  if type(claim.label) ~= "string" or claim.label == "" then
    return nil, "claim-contract-label-missing"
  end
  if claim.label ~= C.active_label(expected and expected.naming, owner) then
    return nil, "claim-label-mismatch"
  end
  if claim.source_ref == nil then
    return nil, "claim-contract-source-ref-missing"
  end
  local source_ref = copy_source_ref(claim.source_ref)
  if source_ref == nil then
    return nil, "claim-contract-source-ref-invalid"
  end
  local expected_source_ref = expected and expected.source_ref
  if expected_source_ref ~= nil
    and (source_ref.kind ~= expected_source_ref.kind or source_ref.ref ~= expected_source_ref.ref) then
    return nil, "source-ref-mismatch"
  end
  return {
    schema = C.label_contract_schema,
    owner = owner,
    label = claim.label,
    source_ref = source_ref,
  }
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
  local normalized_owner = parsers_misc.canonical_login(owner)
  if #assignees == 0 then
    return "unassigned"
  end
  if #assignees == 1
    and parsers_misc.canonical_login(assignees[1]) == normalized_owner then
    return "self"
  end
  return "other"
end

local function is_managed_login(managed, login)
  for candidate, allowed in pairs(type(managed) == "table" and managed or {}) do
    if allowed == true
      and parsers_misc.canonical_login(candidate) == parsers_misc.canonical_login(login) then
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

  local normalized_owner = parsers_misc.canonical_login(owner)
  if mode == "label" then
    for _, login in ipairs(assignees) do
      local normalized = parsers_misc.canonical_login(login)
      if is_managed_login(managed, normalized) and normalized ~= normalized_owner then
        return "other"
      end
    end
    return label_state
  end

  return C.classify_assignees(assignees, normalized_owner)
end

return C
