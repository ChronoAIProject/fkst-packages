<<<<<<< HEAD
local claim_labels = require("devloop.claim_labels")
local github_view = require("forge.github_view")
=======
local github_view = require("forge.github_view")
local claim_carriers = require("devloop.claim_carriers")
local config = require("devloop.config")
local github_author_policy = require("devloop.github_author_policy")
>>>>>>> d295cdfd1ae35c5356810aff077f525933c86fc8

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

<<<<<<< HEAD
function M.gh_issue_view_claim_labels_cmd(repo, issue_number)
  return M.gh_issue_rest_view_cmd(repo, issue_number)
end

function M.parse_issue_claim_labels(stdout)
  local decoded = json.decode(stdout or "{}")
  return github_view.label_names(decoded.labels)
end

function M.issue_claim_held_by_label(repo, issue_number, active_label)
  local view = M.gh_exec(M.gh_issue_view_claim_labels_cmd(repo, issue_number), 30, "GitHub issue REST labels")
  return claim_labels.classify(M.parse_issue_claim_labels(view.stdout), active_label) == "self"
=======
function M.gh_issue_view_ownership_cmd(repo, issue_number)
  return M.gh_issue_rest_view_cmd(repo, issue_number)
end

function M.github_issue_assign(repo, issue_number, login, timeout)
  return M.github().issue_assign(repo, issue_number, login, timeout or 30)
end

function M.github_issue_unassign(repo, issue_number, login, timeout)
  return M.github().issue_unassign(repo, issue_number, login, timeout or 30)
end

local function claim_contract_carrier(claim)
  if type(claim) ~= "table" or claim.owner == nil or tostring(claim.owner) == "" then
    return nil
  end
  local owner = github_author_policy.claim_owner()
  if tostring(claim.owner) ~= owner then
    return nil
  end
  local carrier = config.claim_mode()
  if carrier == "assignee" then
    return claim.label == nil and carrier or nil
  end
  if type(claim.label) ~= "string" or not claim_carriers.is_claim_family(claim.label) then
    return nil
  end
  if claim.label ~= claim_carriers.active_label(config.claim_label_exclusive(), owner) then
    return nil
  end
  return carrier
end

local function issue_claim_held_in_issue(issue, claim, carrier)
  if type(issue) ~= "table"
    or type(issue.assignees) ~= "table"
    or type(issue.labels) ~= "table" then
    return false
  end
  return claim_carriers.classify(
    carrier,
    M.assignee_logins(issue.assignees),
    claim.owner,
    github_view.label_names(issue.labels),
    carrier == "label" and claim.label or nil,
    carrier == "label" and github_author_policy.managed_bot_logins() or nil
  ) == "self"
end

function M.issue_claim_held_by_self(repo, issue_number, claim, carrier)
  local view = M.gh_exec(M.gh_issue_view_ownership_cmd(repo, issue_number), 30, "GitHub issue REST ownership")
  local issue = json.decode(view.stdout or "{}")
  return issue_claim_held_in_issue(issue, claim, carrier)
>>>>>>> d295cdfd1ae35c5356810aff077f525933c86fc8
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
<<<<<<< HEAD
  local active_label = type(claim) == "table" and claim.label or nil
  if type(active_label) ~= "string" or active_label == "" or not claim_labels.is_claim_family(active_label) then
    verify_claim_log(dept, "claim-label-invalid", repo, issue_number, active_label)
    return false
  end
  if not claim_source_ref_matches(payload, repo, issue_number) then
    verify_claim_log(dept, "source-ref-mismatch", repo, issue_number, active_label)
    return false
  end
  if M.issue_claim_held_by_label(repo, issue_number, active_label) then
    return true
  end
  verify_claim_log(dept, "claim-label-lost", repo, issue_number, active_label)
=======
  local carrier = claim_contract_carrier(claim)
  if carrier == nil then
    verify_claim_log(dept, "claim-contract-invalid", repo, issue_number)
    return false
  end
  if not claim_source_ref_matches(payload, repo, issue_number) then
    verify_claim_log(dept, "source-ref-mismatch", repo, issue_number, claim.owner)
    return false
  end
  if M.issue_claim_held_by_self(repo, issue_number, claim, carrier) then
    return true
  end
  verify_claim_log(dept, "ownership-claim-lost", repo, issue_number, claim.owner)
>>>>>>> d295cdfd1ae35c5356810aff077f525933c86fc8
  return false
end

function M.verify_issue_claim_in_issue(issue, payload, repo, issue_number, dept)
  local claim = payload and payload.claim
  if claim == nil then
    return true
  end
<<<<<<< HEAD
  local active_label = type(claim) == "table" and claim.label or nil
  if type(active_label) ~= "string" or active_label == "" or not claim_labels.is_claim_family(active_label) then
    verify_claim_log(dept, "claim-label-invalid", repo, issue_number, active_label)
    return false
  end
  if not claim_source_ref_matches(payload, repo, issue_number) then
    verify_claim_log(dept, "source-ref-mismatch", repo, issue_number, active_label)
    return false
  end
  local labels = github_view.label_names(issue and issue.labels)
  if claim_labels.classify(labels, active_label) == "self" then
    return true
  end
  verify_claim_log(dept, "claim-label-lost", repo, issue_number, active_label)
=======
  local carrier = claim_contract_carrier(claim)
  if carrier == nil then
    verify_claim_log(dept, "claim-contract-invalid", repo, issue_number)
    return false
  end
  if not claim_source_ref_matches(payload, repo, issue_number) then
    verify_claim_log(dept, "source-ref-mismatch", repo, issue_number, claim.owner)
    return false
  end
  if issue_claim_held_in_issue(issue, claim, carrier) then
    return true
  end
  verify_claim_log(dept, "ownership-claim-lost", repo, issue_number, claim.owner)
>>>>>>> d295cdfd1ae35c5356810aff077f525933c86fc8
  return false
end

end

return S
