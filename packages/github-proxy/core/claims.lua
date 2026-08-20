local github_view = require("forge.github_view")
local claim_carriers = require("devloop.claim_carriers")
local config = require("devloop.config")
local github_author_policy = require("devloop.github_author_policy")
local forge_strings = require("forge.strings")

local S = {}

function S.install(M)
local function assignee_login(assignee)
  if type(assignee) == "table" then
    if assignee.login ~= nil then
      return tostring(assignee.login)
    end
    if assignee.name ~= nil then
      return tostring(assignee.name)
    end
  elseif assignee ~= nil then
    return tostring(assignee)
  end
  return nil
end

function M.assignee_logins(value)
  local logins = {}
  if type(value) ~= "table" then
    return logins
  end
  for _, assignee in ipairs(value) do
    local login = assignee_login(assignee)
    if login ~= nil and login ~= "" then
      table.insert(logins, login)
    end
  end
  return logins
end

function M.gh_issue_view_ownership_cmd(repo, issue_number)
  return M.gh_issue_rest_view_cmd(repo, issue_number)
end

local function issue_source_ref(repo, issue_number)
  return {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
end

local function claim_contract_carrier(claim, repo, issue_number)
  if type(claim) == "table" and claim.schema ~= nil then
    local normalized, reason = claim_carriers.validate_label_contract(claim, {
      owner = github_author_policy.claim_owner(),
      naming = config.claim_label_naming(),
      owner_digest_hex_length = config.claim_label_owner_digest_hex_length(),
      source_ref = issue_source_ref(repo, issue_number),
    })
    if normalized == nil then
      return nil, nil, reason
    end
    return "label", normalized, nil
  end
  if type(claim) ~= "table" or claim.owner == nil or tostring(claim.owner) == "" then
    return nil, nil, "claim-contract-invalid"
  end
  local owner = github_author_policy.claim_owner()
  if forge_strings.canonical_login(claim.owner) ~= forge_strings.canonical_login(owner) then
    return nil, nil, "claim-contract-invalid"
  end
  local carrier = config.claim_mode()
  if carrier == "assignee" then
    return claim.label == nil and carrier or nil, claim, claim.label == nil and nil or "claim-contract-invalid"
  end
  if type(claim.label) ~= "string" or not claim_carriers.is_claim_family(claim.label) then
    return nil, nil, "claim-contract-invalid"
  end
  if claim.label ~= claim_carriers.active_label(
    config.claim_label_naming(),
    owner,
    config.claim_label_owner_digest_hex_length()
  ) then
    return nil, nil, "claim-contract-invalid"
  end
  return carrier, claim, nil
end

local function issue_claim_held_in_issue(issue, claim, carrier)
  if type(issue) ~= "table"
    or type(issue.assignees) ~= "table"
    or type(issue.labels) ~= "table" then
    return false
  end
  local held = claim_carriers.classify(
    carrier,
    M.assignee_logins(issue.assignees),
    claim.owner,
    github_view.label_names(issue.labels),
    carrier == "label" and claim.label or nil,
    carrier == "label" and github_author_policy.managed_bot_logins() or nil
  ) == "self"
  if held and carrier == "label" then
    local desired = claim_carriers.active_label_spec(
      config.claim_label_naming(),
      claim.owner,
      config.claim_label_owner_digest_hex_length()
    )
    if desired.owner ~= nil then
      local existing = nil
      for _, label in ipairs(issue.labels) do
        local name = type(label) == "table" and label.name or label
        if tostring(name or "") == desired.name then
          existing = type(label) == "table" and label or { name = name }
          break
        end
      end
      claim_carriers.assert_owner_binding(existing, desired)
    end
  end
  return held
end

function M.issue_claim_held_by_self(repo, issue_number, claim, carrier)
  local view = M.gh_exec(M.gh_issue_view_ownership_cmd(repo, issue_number), 30, "GitHub issue REST ownership")
  local issue = json.decode(view.stdout or "{}")
  return issue_claim_held_in_issue(issue, claim, carrier)
end

local function claim_source_ref_matches(claim, repo, issue_number)
  local source_ref = claim and claim.source_ref
  if type(source_ref) ~= "table" or source_ref.kind ~= "external" then
    return false
  end
  return tostring(source_ref.ref or "") == tostring(repo) .. "#issue/" .. tostring(issue_number)
end

local function verify_claim_log(dept, reason, repo, issue_number, owner)
  local fields = {
    "outcome=lost",
    "reason=" .. tostring(reason),
    "repo=" .. tostring(repo),
    "issue=" .. tostring(issue_number),
  }
  if owner ~= nil and tostring(owner) ~= "" then
    table.insert(fields, "owner=" .. tostring(owner))
  end
  M.log_line("info", dept, "CLAIM", fields)
end

function M.verify_issue_claim_before_write(payload, repo, issue_number, dept)
  local claim = payload and payload.claim
  if claim == nil then
    return true
  end
  local carrier, normalized, contract_reason = claim_contract_carrier(claim, repo, issue_number)
  if carrier == nil then
    local reason = contract_reason or "claim-contract-invalid"
    verify_claim_log(dept, reason, repo, issue_number)
    return false, reason
  end
  claim = normalized or claim
  if not claim_source_ref_matches(claim, repo, issue_number) then
    verify_claim_log(dept, "source-ref-mismatch", repo, issue_number, claim.owner)
    return false, "source-ref-mismatch"
  end
  if M.issue_claim_held_by_self(repo, issue_number, claim, carrier) then
    return true
  end
  verify_claim_log(dept, "ownership-claim-lost", repo, issue_number, claim.owner)
  return false, "ownership-claim-lost"
end

function M.verify_issue_claim_in_issue(issue, payload, repo, issue_number, dept)
  local claim = payload and payload.claim
  if claim == nil then
    return true
  end
  local carrier, normalized, contract_reason = claim_contract_carrier(claim, repo, issue_number)
  if carrier == nil then
    local reason = contract_reason or "claim-contract-invalid"
    verify_claim_log(dept, reason, repo, issue_number)
    return false, reason
  end
  claim = normalized or claim
  if not claim_source_ref_matches(claim, repo, issue_number) then
    verify_claim_log(dept, "source-ref-mismatch", repo, issue_number, claim.owner)
    return false, "source-ref-mismatch"
  end
  if issue_claim_held_in_issue(issue, claim, carrier) then
    return true
  end
  verify_claim_log(dept, "ownership-claim-lost", repo, issue_number, claim.owner)
  return false, "ownership-claim-lost"
end

end

return S
