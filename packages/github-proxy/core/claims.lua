local github_view = require("forge.github_view")
local claim_carriers = require("devloop.claim_carriers")
local config = require("devloop.config")
local github_author_policy = require("devloop.github_author_policy")
local forge_strings = require("forge.strings")

local S = {}

function S.install(M)
function M.gh_issue_view_claim_labels_cmd(repo, issue_number)
  return M.gh_issue_rest_view_cmd(repo, issue_number)
end

local function claim_contract_valid(claim)
  if type(claim) ~= "table" or claim.owner == nil or tostring(claim.owner) == "" then
    return false
  end
  local owner = github_author_policy.claim_owner()
  if forge_strings.canonical_login(claim.owner) ~= forge_strings.canonical_login(owner) then
    return false
  end
  if type(claim.label) ~= "string" or not claim_carriers.is_claim_family(claim.label) then
    return false
  end
  return claim.label == claim_carriers.active_label(config.claim_label_exclusive(), owner)
end

local function issue_claim_held_in_issue(issue, claim)
  if type(issue) ~= "table" or type(issue.labels) ~= "table" then
    return false
  end
  if claim_carriers.classify_labels(github_view.label_names(issue.labels), claim.label) ~= "self" then
    return false
  end
  local desired = claim_carriers.active_label_spec(config.claim_label_exclusive(), claim.owner)
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
  return true
end

function M.issue_claim_held_by_label(repo, issue_number, claim)
  local view = M.gh_exec(M.gh_issue_view_claim_labels_cmd(repo, issue_number), 30, "GitHub issue REST labels")
  local issue = json.decode(view.stdout or "{}")
  return issue_claim_held_in_issue(issue, claim)
end

local function claim_source_ref_matches(payload, repo, issue_number)
  local claim = payload and payload.claim
  local source_ref = claim and claim.source_ref
  if type(source_ref) ~= "table" or source_ref.kind ~= "external" then
    return false
  end
  return tostring(source_ref.ref or "") == tostring(repo) .. "#issue/" .. tostring(issue_number)
end

local function verify_claim_log(dept, reason, repo, issue_number, active_label)
  local fields = {
    "outcome=lost",
    "reason=" .. tostring(reason),
    "repo=" .. tostring(repo),
    "issue=" .. tostring(issue_number),
  }
  if active_label ~= nil and tostring(active_label) ~= "" then
    table.insert(fields, "label=" .. tostring(active_label))
  end
  M.log_line("info", dept, "CLAIM", fields)
end

function M.verify_issue_claim_before_write(payload, repo, issue_number, dept)
  local claim = payload and payload.claim
  if claim == nil then
    return true
  end
  local active_label = type(claim) == "table" and claim.label or nil
  if not claim_contract_valid(claim) then
    verify_claim_log(dept, "claim-contract-invalid", repo, issue_number, active_label)
    return false
  end
  if not claim_source_ref_matches(payload, repo, issue_number) then
    verify_claim_log(dept, "source-ref-mismatch", repo, issue_number, active_label)
    return false
  end
  if M.issue_claim_held_by_label(repo, issue_number, claim) then
    return true
  end
  verify_claim_log(dept, "claim-label-lost", repo, issue_number, active_label)
  return false
end

function M.verify_issue_claim_in_issue(issue, payload, repo, issue_number, dept)
  local claim = payload and payload.claim
  if claim == nil then
    return true
  end
  local active_label = type(claim) == "table" and claim.label or nil
  if not claim_contract_valid(claim) then
    verify_claim_log(dept, "claim-contract-invalid", repo, issue_number, active_label)
    return false
  end
  if not claim_source_ref_matches(payload, repo, issue_number) then
    verify_claim_log(dept, "source-ref-mismatch", repo, issue_number, active_label)
    return false
  end
  if issue_claim_held_in_issue(issue, claim) then
    return true
  end
  verify_claim_log(dept, "claim-label-lost", repo, issue_number, active_label)
  return false
end

end

return S
