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

-- Single source for the claim owner: normalize the configured bot login so all
-- downstream comparisons get the bare slug regardless of whether the deployment
-- configured "<slug>" or "<slug>[bot]". No-op for ordinary user logins.
function M.claim_owner()
  return M.strip_bot_login_suffix(M.assert_trusted_bot_configured() or M.trusted_bot_login())
end

local claimed_label = "fkst-dev:claimed"

function M.claimed_label()
  return claimed_label
end

-- assignee (default) ⇒ exactly today's behavior. label ⇒ opt-in GitHub App mode.
function M.claim_mode_active()
  return M.claim_mode()
end

-- assignee-mode (default): ownership is the current single self-assignee.
-- label-mode (opt-in): ownership is the presence of the fkst-dev:claimed label.
-- labels is optional/extra and ignored in assignee-mode, so existing 2-arg
-- callers keep byte-for-byte behavior.
function M.issue_claim_state(assignees, owner, labels)
  if M.claim_mode() == "label" then
    if M.has_label(labels, claimed_label) then
      return "self"
    end
    return "unassigned"
  end
  local logins = M.assignee_logins(assignees)
  if #logins == 0 then
    return "unassigned"
  end
  if #logins == 1 and M.strip_bot_login_suffix(logins[1]) == tostring(owner or "") then
    return "self"
  end
  return "other"
end

function M.is_self_owned_issue(ownership, owner)
  if type(ownership) ~= "table" then
    return false
  end
  local claim_state = M.issue_claim_state(ownership.assignees, owner, ownership.labels)
  if claim_state == "self" then
    return true
  end
  if claim_state ~= "unassigned" then
    return false
  end
  -- Unassigned+self-author is intentional for fork-and-block isolation: a different bot login sees author!=self and skips.
  local author = M.issue_author_login(ownership)
  if author == nil then
    return false
  end
  return M.strip_bot_login_suffix(author) == tostring(owner or "")
end

function M.gh_issue_assign_cmd(repo, issue_number, login)
  return "gh issue edit " .. M._shell_single_quote(issue_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --add-assignee " .. M._shell_single_quote(login)
end

function M.gh_issue_unassign_cmd(repo, issue_number, login)
  return "gh issue edit " .. M._shell_single_quote(issue_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --remove-assignee " .. M._shell_single_quote(login)
end

-- label-mode claim/unclaim: a GitHub App can add/remove a label even though it
-- cannot be an issue assignee.
function M.gh_issue_add_claim_label_cmd(repo, issue_number)
  return "gh issue edit " .. M._shell_single_quote(issue_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --add-label " .. M._shell_single_quote(claimed_label)
end

function M.gh_issue_remove_claim_label_cmd(repo, issue_number)
  return "gh issue edit " .. M._shell_single_quote(issue_number)
    .. " --repo " .. M._shell_single_quote(repo)
    .. " --remove-label " .. M._shell_single_quote(claimed_label)
end

-- label-mode needs labels in the claim view; assignee-mode keeps the existing
-- assignees,author projection unchanged.
function M.gh_issue_view_claim_ownership_cmd(repo, issue_number)
  if M.claim_mode() == "label" then
    return M.gh_issue_view_cmd(repo, issue_number, "assignees,author,labels")
  end
  return M.gh_issue_view_claim_cmd(repo, issue_number)
end

function M.read_current_issue_assignees(repo, issue_number)
  local ownership = M.read_current_issue_ownership(repo, issue_number)
  return M.assignee_logins(ownership and ownership.assignees)
end

local function decoded_label_names(decoded)
  local labels = {}
  for _, label in ipairs((decoded and decoded.labels) or {}) do
    if type(label) == "table" and label.name ~= nil then
      table.insert(labels, tostring(label.name))
    elseif type(label) == "string" then
      table.insert(labels, label)
    end
  end
  return labels
end

function M.read_current_issue_ownership(repo, issue_number)
  if issue_number == nil then
    return nil
  end
  local view = M.gh_exec({ cmd = M.gh_issue_view_claim_ownership_cmd(repo, issue_number), timeout = 30 })
  if view.exit_code ~= 0 then
    error("github-devloop: gh issue claim view failed: " .. tostring(view.stderr))
  end
  local decoded = json.decode(view.stdout or "{}")
  return {
    assignees = M.assignee_logins(decoded.assignees),
    author_login = M.issue_author_login(decoded),
    labels = decoded_label_names(decoded),
  }
end

function M.verify_issue_claim(repo, issue_number, owner)
  local ownership = M.read_current_issue_ownership(repo, issue_number)
  return M.issue_claim_state(ownership and ownership.assignees, owner, ownership and ownership.labels) == "self"
end

local function log_claim(dept, proposal_id, action, reason)
  M.log_cas_decision(dept, proposal_id, { state = nil, version = nil }, "claim", "claim", action, reason)
end

function M.verify_pr_review_issue_claim(dept, repo, issue_number, current_issue, proposal_id)
  if issue_number == nil then
    log_claim(dept, proposal_id, "skip-not-owned", "backing issue is absent")
    return false
  end
  local owner = M.claim_owner()
  local ownership = nil
  local current_usable
  if M.claim_mode() == "label" then
    -- label-mode ownership is derived from the labels projection.
    current_usable = type(current_issue) == "table" and current_issue.labels ~= nil
  else
    current_usable = type(current_issue) == "table"
      and current_issue.assignees ~= nil
      and M.issue_author_login(current_issue) ~= nil
  end
  if current_usable then
    ownership = current_issue
  else
    ownership = M.read_current_issue_ownership(repo, issue_number)
  end
  if M.is_self_owned_issue(ownership, owner) then
    return true
  end
  local status = M.issue_claim_state(ownership and ownership.assignees, owner, ownership and ownership.labels)
  if status == "other" then
    log_claim(dept, proposal_id, "skip-claimed-by-other", "backing issue assignee claim is held by another login")
  else
    log_claim(dept, proposal_id, "skip-not-owned", "backing issue is not self-owned")
  end
  return false
end

function M.fork_first_observed_key(repo, issue_number, progress_key)
  local parts = {
    "github-devloop",
    "fork-first-observed",
    M.safe_repo(repo),
    "issue",
    M.safe_issue(issue_number),
  }
  if progress_key ~= nil and tostring(progress_key) ~= "" then
    table.insert(parts, M.safe_updated_at(progress_key))
  end
  return M._dedup_key(parts)
end

function M.fork_grace_seconds(exec)
  local raw = M.read_env("FKST_DEVLOOP_FORK_GRACE_HOURS", exec)
  raw = M._trim(raw or "")
  if raw == "" then
    return 3 * 60 * 60
  end
  local hours = tonumber(raw)
  if hours == nil or hours <= 0 or hours > 168 then
    error("github-devloop: invalid FKST_DEVLOOP_FORK_GRACE_HOURS")
  end
  return math.floor(hours * 60 * 60)
end

function M.fork_grace_elapsed(repo, issue_number, current, now_seconds, grace_seconds)
  local current_seconds = tonumber(now_seconds)
  local grace = tonumber(grace_seconds)
  if current_seconds == nil or grace == nil then
    return false, "fork-grace-age-unknown"
  end
  local progress_key = current and (current.updated_at or current.updatedAt)
  local observed_key = M.fork_first_observed_key(repo, issue_number, progress_key)
  local first_observed_seconds = tonumber(cache_get(observed_key) or "")
  if first_observed_seconds == nil then
    cache_set(observed_key, tostring(current_seconds))
    return false, "fork-grace-started"
  end
  if current_seconds - first_observed_seconds < grace then
    return false, "fork-grace-pending"
  end
  return true, "fork-grace-elapsed", current_seconds - first_observed_seconds
end

function M.claim_issue_for_management(dept, repo, issue_number, current, proposal_id)
  local owner = M.claim_owner()
  local status = M.issue_claim_state(current and current.assignees, owner, current and current.labels)
  if status == "self" then
    return true
  end
  if status == "other" then
    log_claim(dept, proposal_id, "skip-claimed-by-other", "issue assignee claim is held by another login")
    return false
  end

  local author = M.issue_author_login(current)
  if author == nil or author == "" then
    log_claim(dept, proposal_id, "skip-fork-author-unknown", "issue author is missing or unknown")
    return false
  end
  author = M.strip_bot_login_suffix(author)
  -- Fork-and-block isolation (grace + fork of other-authored issues) is an
  -- assignee-mode policy: it keeps an assignee-claim bot from intruding on a
  -- human's issue. In label-mode the loop is single-tenant and explicitly
  -- opts issues in via the fkst-dev:enabled label, so it claims directly
  -- (matching the label-claim fork). Assignee-mode keeps the original behavior.
  if M.claim_mode() ~= "label" and author ~= owner then
    local dedup_key = M.fork_issue_dedup_key(repo, issue_number)
    if M.has_trusted_issue_create_parent_marker(current and current.comments, dedup_key, owner) then
      log_claim(dept, proposal_id, "fork-present", "trusted fork issue-create ledger marker already exists")
      return false
    end
    local elapsed = M.fork_grace_elapsed(repo, issue_number, current, now(), M.fork_grace_seconds())
    if not elapsed then
      log_claim(dept, proposal_id, "skip-fork-grace", "other-authored unassigned issue is inside fork grace window")
      return false
    end
    current = M.rederive_issue_state(repo, issue_number)
    local request, request_reason = M.build_fork_issue_create_request(repo, issue_number, current, M.issue_source_ref(repo, issue_number))
    if request == nil then
      log_claim(dept, proposal_id, "skip-fork-" .. tostring(request_reason or "invalid"), "fork request could not be built from current issue")
      return false
    end
    if M.has_trusted_issue_create_parent_marker(current and current.comments, request.dedup_key, owner) then
      log_claim(dept, proposal_id, "fork-present", "trusted fork issue-create ledger marker already exists")
      return false
    end
    log_claim(dept, proposal_id, "fork-raised", "other-authored unassigned issue is forked before management")
    M.log_raise(dept, proposal_id, "github-proxy.github_issue_create_request", request)
    return false
  end

  if M.read_env("FKST_GITHUB_WRITE") ~= "1" then
    log_claim(dept, proposal_id, "dry-run-claim", "FKST_GITHUB_WRITE!=1")
    return true
  end

  if M.claim_mode() == "label" then
    local claimed = M.gh_exec({ cmd = M.gh_issue_add_claim_label_cmd(repo, issue_number), timeout = 30 })
    if claimed.exit_code ~= 0 then
      error("github-devloop: gh issue edit add claim label failed: " .. tostring(claimed.stderr))
    end
    M.invalidate_entity_after_write(repo, "issue", issue_number)
    if M.verify_issue_claim(repo, issue_number, owner) then
      log_claim(dept, proposal_id, "claim-won", "label claim verified after add-label")
      return true
    end

    local unclaimed = M.gh_exec({ cmd = M.gh_issue_remove_claim_label_cmd(repo, issue_number), timeout = 30 })
    if unclaimed.exit_code ~= 0 then
      error("github-devloop: gh issue edit remove claim label failed: " .. tostring(unclaimed.stderr))
    end
    M.invalidate_entity_after_write(repo, "issue", issue_number)
    log_claim(dept, proposal_id, "claim-lost", "label claim lost after add-label verification")
    return false
  end

  local assigned = M.gh_exec({ cmd = M.gh_issue_assign_cmd(repo, issue_number, owner), timeout = 30 })
  if assigned.exit_code ~= 0 then
    error("github-devloop: gh issue edit assign failed: " .. tostring(assigned.stderr))
  end
  M.invalidate_entity_after_write(repo, "issue", issue_number)
  if M.verify_issue_claim(repo, issue_number, owner) then
    log_claim(dept, proposal_id, "claim-won", "assignee claim verified after assign")
    return true
  end

  local unassigned = M.gh_exec({ cmd = M.gh_issue_unassign_cmd(repo, issue_number, owner), timeout = 30 })
  if unassigned.exit_code ~= 0 then
    error("github-devloop: gh issue edit unassign failed: " .. tostring(unassigned.stderr))
  end
  M.invalidate_entity_after_write(repo, "issue", issue_number)
  log_claim(dept, proposal_id, "claim-lost", "assignee claim lost after assign verification")
  return false
end

function M.claim_required_payload(source_ref)
  local normalized = M.normalize_source_ref(source_ref)
  local repo, issue_number = M.parse_issue_source_ref(normalized)
  if repo == nil or issue_number == nil then
    return nil
  end
  return {
    owner = M.claim_owner(),
    source_ref = normalized,
  }
end

function M.attach_issue_claim(payload, source_ref)
  if type(payload) ~= "table" then
    return payload
  end
  -- github-proxy's pre-write guard verifies the attached claim against the
  -- issue's ASSIGNEES. In label-mode the owner is a GitHub App, which holds the
  -- fkst-dev:claimed label but is never an assignee, so an attached assignee
  -- claim would always read as "lost" and block every write. Ownership in
  -- label-mode is instead verified at claim time (claim_issue_for_management),
  -- so skip attaching the assignee claim and let github-proxy's no-claim path
  -- proceed. Assignee-mode is unchanged.
  if M.claim_mode() == "label" then
    return payload
  end
  payload.claim = M.claim_required_payload(source_ref or payload.source_ref)
  return payload
end

end

return S
