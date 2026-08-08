local claim_labels = require("devloop.claim_labels")
local github_view = require("forge.github_view")

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
  return false
end

function M.verify_issue_claim_in_issue(issue, payload, repo, issue_number, dept)
  local claim = payload and payload.claim
  if claim == nil then
    return true
  end
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
  return false
end

end

return S
