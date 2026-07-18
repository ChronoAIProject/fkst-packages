local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local C = {}
local github_handle = nil
local github_factory = require("devloop.github_factory")
local error_facts = require("contract.error_facts")
local contract_time = require("contract.time")
local config = require("devloop.config")
local github_author_policy = require("devloop.github_author_policy")
local github_view = require("forge.github_view")
local github_proxy_entity_view = require("devloop.github_proxy_entity_view")
local devloop_logging = require("devloop.logging")
local marker_shared = require("devloop.markers.shared")
local forks_handle = nil
local devloop_state_handle = nil

local function forks()
  if forks_handle == nil then
    forks_handle = require("devloop.forks")
  end
  return forks_handle
end

local function github()
  if type(fkst) == "table" and type(fkst.test) == "table" then
    if type(github_factory.reset_production_handle_for_tests) == "function" then
      github_factory.reset_production_handle_for_tests()
    end
    github_handle = nil
  elseif github_handle ~= nil then
    return github_handle
  end
  if type(exec_argv) ~= "function" then
    error("github-devloop: GitHub adapter requires exec_argv")
  end
  github_handle = github_factory.production_handle()
  return github_handle
end

local function devloop_state()
  if devloop_state_handle == nil then
    devloop_state_handle = require("devloop.state")
  end
  return devloop_state_handle
end

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

local function issue_author_login(issue)
  if type(issue) ~= "table" then
    return nil
  end
  if issue.author_login ~= nil and tostring(issue.author_login) ~= "" then
    return tostring(issue.author_login)
  end
  if type(issue.author) == "table" and issue.author.login ~= nil and tostring(issue.author.login) ~= "" then
    return tostring(issue.author.login)
  end
  if type(issue.user) == "table" and issue.user.login ~= nil and tostring(issue.user.login) ~= "" then
    return tostring(issue.user.login)
  end
  return nil
end

function C.issue_author_login(issue)
  return issue_author_login(issue)
end

function C.assignee_logins(value)
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
function C.claim_owner()
  return devloop_base.strip_bot_login_suffix(devloop_base.assert_trusted_bot_configured() or devloop_base.trusted_bot_login())
end

function C.managed_bot_logins(exec)
  local raw = devloop_base.read_env("FKST_DEVLOOP_MANAGED_BOT_LOGINS", exec)
  local logins = {}
  for entry in tostring(raw or ""):gmatch("[^,%s]+") do
    local login = devloop_base.strip_bot_login_suffix(strings.trim(entry))
    if login ~= nil and login ~= "" then
      logins[login] = true
    end
  end
  return logins
end

function C.is_managed_bot_login(login, managed)
  local normalized = devloop_base.strip_bot_login_suffix(login)
  return normalized ~= nil and normalized ~= "" and type(managed) == "table" and managed[normalized] == true
end

local claimed_label = "fkst-dev:claimed"
local state_marker_pattern = "<!%-%- fkst:github%-devloop:state:v1.-%-%->"
local peer_activity_scan_limit = 100
local marker_attr = marker_shared.marker_attr

local function decode_json_array(result)
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return nil
  end
  local ok, decoded = pcall(json.decode, result.stdout or "[]")
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

function C.claimed_label()
  return claimed_label
end

local function comment_body(comment)
  if type(comment) == "table" and comment.body ~= nil then
    return tostring(comment.body)
  end
  return nil
end

local function github_actor_login(value)
  if type(value) ~= "table" then
    return nil
  end
  local seen = {}
  local only = nil
  local function add(login)
    local normalized = devloop_base.strip_bot_login_suffix(login)
    if normalized == nil or normalized == "" then
      return
    end
    seen[normalized] = true
    only = normalized
  end
  add(value.author_login)
  if type(value.author) == "table" then
    add(value.author.login)
  end
  if type(value.user) == "table" then
    add(value.user.login)
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  if count ~= 1 then
    return nil
  end
  return only
end

local function has_state_marker_comment(body)
  if type(body) ~= "string" then
    return false
  end
  for marker in body:gmatch(state_marker_pattern) do
    if marker_attr(marker, "proposal") ~= nil
      and devloop_state().is_state(marker_attr(marker, "state"))
      and marker_attr(marker, "version") ~= nil then
      return true
    end
  end
  return false
end

local function add_authorized_candidate(logins, login, trusted_author_policy, owner)
  if type(logins) ~= "table" or type(trusted_author_policy) ~= "table" then
    return
  end
  local normalized = devloop_base.strip_bot_login_suffix(login)
  local normalized_owner = devloop_base.strip_bot_login_suffix(owner)
  if normalized ~= nil and normalized ~= "" and normalized ~= normalized_owner
    and github_author_policy.is_authorized(trusted_author_policy, normalized) then
    logins[normalized] = true
  end
end

local function add_state_marker_comment_candidates(logins, comments, trusted_author_policy, owner)
  if type(comments) ~= "table" then
    return
  end
  for _, comment in ipairs(comments) do
    local body = comment_body(comment)
    if has_state_marker_comment(body) then
      add_authorized_candidate(logins, github_actor_login(comment), trusted_author_policy, owner)
    end
  end
end

function C.observed_state_marker_managed_bot_logins(current, trusted_author_policy, owner)
  local logins = {}
  if type(current) ~= "table" or type(current.comments) ~= "table" or type(trusted_author_policy) ~= "table" then
    return logins
  end
  add_state_marker_comment_candidates(logins, current.comments, trusted_author_policy, owner)
  return logins
end

local function add_observed_state_marker_managed_bot_logins(managed, current, trusted_author_policy, owner)
  for login, allowed in pairs(C.observed_state_marker_managed_bot_logins(current, trusted_author_policy, owner)) do
    if allowed == true then
      managed[login] = true
    end
  end
end

local function issue_row_comments(row)
  if type(row) ~= "table" or type(row.comments) ~= "table" then
    return {}
  end
  return row.comments
end

local function pr_head_branch(row)
  if type(row) ~= "table" then
    return nil
  end
  if row.headRefName ~= nil then
    return tostring(row.headRefName)
  end
  if type(row.head) == "table" and row.head.ref ~= nil then
    return tostring(row.head.ref)
  end
  return nil
end

local function pr_base_branch(row)
  if type(row) ~= "table" then
    return nil
  end
  if row.baseRefName ~= nil then
    return tostring(row.baseRefName)
  end
  if type(row.base) == "table" and row.base.ref ~= nil then
    return tostring(row.base.ref)
  end
  return nil
end

function C.repo_scoped_observed_managed_bot_logins(repo, trusted_author_policy, owner, github_handle)
  local logins = {}
  if type(trusted_author_policy) ~= "table" or repo == nil or tostring(repo) == "" then
    return logins
  end
  local handle = github_handle or github()
  local ok_issues, issues = pcall(function()
    return handle.issue_list_cli(repo, "all", peer_activity_scan_limit, "number,comments,author", 30)
  end)
  if ok_issues then
    for _, row in ipairs(decode_json_array(issues) or {}) do
      add_state_marker_comment_candidates(logins, issue_row_comments(row), trusted_author_policy, owner)
    end
  end

  local ok_config, branches = pcall(config.branch_config)
  local upstream = ok_config and branches and branches.upstream or nil
  local integration = ok_config and branches and branches.integration or nil
  if upstream == nil or tostring(upstream) == "" or integration == nil or tostring(integration) == "" then
    return logins
  end
  local ok_prs, prs = pcall(function()
    return handle.pr_list_cli(repo, "all", peer_activity_scan_limit, "number,headRefName,baseRefName,comments,author", 30)
  end)
  if not ok_prs then
    return logins
  end
  for _, row in ipairs(decode_json_array(prs) or {}) do
    add_state_marker_comment_candidates(logins, issue_row_comments(row), trusted_author_policy, owner)
    if pr_base_branch(row) == tostring(upstream) and pr_head_branch(row) == tostring(integration) then
      add_authorized_candidate(logins, github_actor_login(row), trusted_author_policy, owner)
    end
  end
  return logins
end

local function add_repo_scoped_observed_managed_bot_logins(managed, repo, trusted_author_policy, owner, github_handle)
  for login, allowed in pairs(C.repo_scoped_observed_managed_bot_logins(repo, trusted_author_policy, owner, github_handle)) do
    if allowed == true then
      managed[login] = true
    end
  end
end

-- assignee (default) ⇒ exactly today's behavior. label ⇒ opt-in GitHub App mode.
function C.claim_mode_active()
  return config.claim_mode()
end

-- assignee-mode (default): ownership is the current single self-assignee.
-- label-mode (opt-in): ownership is the presence of the fkst-dev:claimed label.
-- labels is optional/extra and ignored in assignee-mode, so existing 2-arg
-- callers keep byte-for-byte behavior.
function C.issue_claim_state(assignees, owner, labels)
  if config.claim_mode() == "label" then
    if devloop_state().has_label(labels, claimed_label) then
      return "self"
    end
    return "unassigned"
  end
  local logins = C.assignee_logins(assignees)
  if #logins == 0 then
    return "unassigned"
  end
  if #logins == 1 and devloop_base.strip_bot_login_suffix(logins[1]) == tostring(owner or "") then
    return "self"
  end
  return "other"
end

function C.is_self_owned_issue(ownership, owner)
  if type(ownership) ~= "table" then
    return false
  end
  local claim_state = C.issue_claim_state(ownership.assignees, owner, ownership.labels)
  if claim_state == "self" then
    return true
  end
  if claim_state ~= "unassigned" then
    return false
  end
  -- Unassigned+self-author is intentional for fork-and-block isolation: a different bot login sees author!=self and skips.
  local author = C.issue_author_login(ownership)
  if author == nil then
    return false
  end
  return devloop_base.strip_bot_login_suffix(author) == tostring(owner or "")
end

function C.read_current_issue_assignees(repo, issue_number)
  local ownership = C.read_current_issue_ownership(repo, issue_number)
  return C.assignee_logins(ownership and ownership.assignees)
end

local function issue_labels(decoded)
  return github_view.label_names(decoded and decoded.labels)
end

function C.read_current_issue_ownership(repo, issue_number)
  if issue_number == nil then
    return nil
  end
  local fields = "assignees,author"
  if config.claim_mode() == "label" then
    fields = "assignees,author,labels"
  end
  local view = github().issue_view(repo, issue_number, fields, 30)
  local decoded = json.decode(view.stdout or "{}")
  return {
    assignees = C.assignee_logins(decoded.assignees),
    author_login = C.issue_author_login(decoded),
    labels = issue_labels(decoded),
  }
end

function C.verify_issue_claim(repo, issue_number, owner)
  local ownership = C.read_current_issue_ownership(repo, issue_number)
  return C.issue_claim_state(ownership and ownership.assignees, owner, ownership and ownership.labels) == "self"
end

local function log_claim(dept, proposal_id, action, reason)
  devloop_logging.log_cas_decision(dept, proposal_id, { state = nil, version = nil }, "claim", "claim", action, reason)
end

local function log_terminal_skip(dept, proposal_id, queue, source_ref, error_class, why)
  local fields = error_facts.error_fact_fields(error_class, queue, dept, why, {
    source_ref = source_ref,
    terminal = true,
  })
  table.insert(fields, "WHY=" .. error_facts.one_line(why))
  devloop_logging.log_line("warn", dept, proposal_id, "SKIP", fields)
end

local function is_assign_permission_denied(err)
  return type(err) == "table" and err.class == "gh-issue-assign-permission-denied"
end

local function issue_source_ref(repo, issue_number)
  return {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
end

function C.verify_pr_review_issue_claim(dept, repo, issue_number, current_issue, proposal_id)
  if issue_number == nil then
    log_claim(dept, proposal_id, "skip-not-owned", "backing issue is absent")
    return false
  end
  local owner = C.claim_owner()
  local ownership = nil
  local current_usable
  if config.claim_mode() == "label" then
    -- label-mode ownership is derived from the labels projection.
    current_usable = type(current_issue) == "table" and current_issue.labels ~= nil
  else
    current_usable = type(current_issue) == "table"
      and current_issue.assignees ~= nil
      and C.issue_author_login(current_issue) ~= nil
  end
  if current_usable then
    ownership = current_issue
  else
    ownership = C.read_current_issue_ownership(repo, issue_number)
  end
  if C.is_self_owned_issue(ownership, owner) then
    return true
  end
  local status = C.issue_claim_state(ownership and ownership.assignees, owner, ownership and ownership.labels)
  if status == "other" then
    log_claim(dept, proposal_id, "skip-claimed-by-other", "backing issue assignee claim is held by another login")
  else
    log_claim(dept, proposal_id, "skip-not-owned", "backing issue is not self-owned")
  end
  return false
end

function C.fork_grace_seconds(exec)
  local raw = devloop_base.read_env("FKST_DEVLOOP_FORK_GRACE_HOURS", exec)
  raw = strings.trim(raw or "")
  if raw == "" then
    return 3 * 60 * 60
  end
  local hours = tonumber(raw)
  if hours == nil or hours <= 0 or hours > 168 then
    error("github-devloop: invalid FKST_DEVLOOP_FORK_GRACE_HOURS")
  end
  return math.floor(hours * 60 * 60)
end

function C.fork_grace_elapsed(repo, issue_number, current, now_seconds, grace_seconds)
  local current_seconds = tonumber(now_seconds)
  local grace = tonumber(grace_seconds)
  if current_seconds == nil or grace == nil then
    return false, "fork-grace-age-unknown", nil
  end

  local created_seconds = contract_time.iso_timestamp_epoch_seconds(current and (current.created_at or current.createdAt))
  if created_seconds == nil then
    return false, "fork-grace-age-unknown", nil
  end

  local age_seconds = current_seconds - created_seconds
  if age_seconds < 0 then
    age_seconds = 0
  end

  if age_seconds < grace then
    return false, "fork-grace-pending", age_seconds
  end
  return true, "fork-grace-elapsed", age_seconds
end

function C.claim_admission_inputs(current, repo)
  local owner = C.claim_owner()
  local status = C.issue_claim_state(current and current.assignees, owner, current and current.labels)
  if status == "other" then
    return {
      owner = owner,
      status = status,
    }
  end

  local claim_mode = config.claim_mode()
  local author = C.issue_author_login(current)
  if author ~= nil and author ~= "" then
    author = devloop_base.strip_bot_login_suffix(author)
  end
  local managed = nil
  local trusted_author_policy = nil
  if claim_mode ~= "label" and author ~= nil and author ~= "" and author ~= owner then
    managed = C.managed_bot_logins()
    if not C.is_managed_bot_login(author, managed) then
      local github_handle = github()
      trusted_author_policy = github_author_policy.from_handle_policy(github_handle)
      add_observed_state_marker_managed_bot_logins(managed, current, trusted_author_policy, owner)
      if not C.is_managed_bot_login(author, managed) then
        add_repo_scoped_observed_managed_bot_logins(managed, repo or (current and current.repo), trusted_author_policy, owner, github_handle)
      end
    end
  end
  return {
    owner = owner,
    status = status,
    claim_mode = claim_mode,
    managed = managed,
    trusted_author_policy = trusted_author_policy,
  }
end

function C.claim_admission_precheck(current, inputs)
  local author = C.issue_author_login(current)
  if author ~= nil and author ~= "" then
    author = devloop_base.strip_bot_login_suffix(author)
  end
  local detail = {
    owner = inputs.owner,
    status = inputs.status,
    claim_mode = inputs.claim_mode,
    author = author,
    managed = inputs.managed,
  }
  if inputs.status == "other" then
    return "other", {
      action = "skip-claimed-by-other",
      reason = "issue assignee claim is held by another login",
    }
  end

  if inputs.claim_mode ~= "label" then
    if author == nil or author == "" then
      return "denied", {
        action = "skip-fork-author-unknown",
        reason = "issue author is missing or unknown",
      }
    end
    if author ~= inputs.owner then
      if C.is_managed_bot_login(author, inputs.managed) then
        if inputs.status == "self" then
          return "held", detail
        end
        return "denied", {
          action = "skip-fork-peer-bot",
          reason = "other-authored unassigned issue belongs to a managed bot login",
        }
      end
      if not github_author_policy.is_authorized(inputs.trusted_author_policy, author) then
        return "denied", {
          action = "skip-non-whitelisted-author",
          reason = "other-authored issue author is not authorized for GitHub content",
        }
      end
    end
  end
  if inputs.status == "self" then
    return "held", detail
  end
  if author == nil or author == "" then
    return "denied", {
      action = "skip-fork-author-unknown",
      reason = "issue author is missing or unknown",
    }
  end
  return "needs-claim", detail
end

function C.log_claim_admission_skip(dept, proposal_id, detail)
  log_claim(dept, proposal_id, detail.action, detail.reason)
end

function C.claim_issue_for_management(M, dept, repo, issue_number, current, proposal_id, admission, detail)
  if admission == nil then
    admission, detail = C.claim_admission_precheck(current, C.claim_admission_inputs(current, repo))
  end
  if admission == "held" then
    return true
  end
  if admission == "other" or admission == "denied" then
    C.log_claim_admission_skip(dept, proposal_id, detail)
    return false
  end
  if admission ~= "needs-claim" then
    error("github-devloop: invalid claim admission decision")
  end
  local owner = detail.owner
  local claim_mode = detail.claim_mode
  local author = detail.author
  local managed = detail.managed
  -- Fork-and-block isolation (grace + fork of other-authored issues) is an
  -- assignee-mode policy: it keeps an assignee-claim bot from intruding on a
  -- human's issue. In label-mode the loop is single-tenant and explicitly
  -- opts issues in via the fkst-dev:enabled label, so it claims directly
  -- (matching the label-claim fork). Assignee-mode isolates only authors admitted
  -- by the canonical GitHub content policy.
  if claim_mode ~= "label" and author ~= owner then
    local dedup_key = forks().fork_issue_dedup_key(repo, issue_number)
    if forks().has_trusted_issue_create_parent_marker(M, current and current.comments, dedup_key, owner, managed) then
      log_claim(dept, proposal_id, "fork-present", "trusted fork issue-create ledger marker already exists")
      return false
    end
    local grace_seconds = C.fork_grace_seconds()
    local elapsed, grace_reason, age_seconds = C.fork_grace_elapsed(repo, issue_number, current, now(), grace_seconds)
    if not elapsed then
      local reason = "other-authored unassigned issue is inside fork grace window"
        .. " reason=" .. tostring(grace_reason)
        .. " age_seconds=" .. tostring(age_seconds or "unknown")
        .. " grace_seconds=" .. tostring(grace_seconds)
      log_claim(dept, proposal_id, "skip-fork-grace", reason)
      return false
    end
    current = forks().rederive_issue_state(M, repo, issue_number)
    local request, request_reason = forks().build_fork_issue_create_request(M, repo, issue_number, current, require("devloop.entity").issue_source_ref(repo, issue_number))
    if request == nil then
      log_claim(dept, proposal_id, "skip-fork-" .. tostring(request_reason or "invalid"), "fork request could not be built from current issue")
      return false
    end
    if forks().has_trusted_issue_create_parent_marker(M, current and current.comments, request.dedup_key, owner, managed) then
      log_claim(dept, proposal_id, "fork-present", "trusted fork issue-create ledger marker already exists")
      return false
    end
    log_claim(dept, proposal_id, "fork-raised", "other-authored unassigned issue is forked before management")
    devloop_logging.log_raise(dept, proposal_id, "github-proxy.github_issue_create_request", request)
    return false
  end

  if devloop_base.read_env("FKST_GITHUB_WRITE") ~= "1" then
    log_claim(dept, proposal_id, "dry-run-claim", "FKST_GITHUB_WRITE!=1")
    return true
  end

  if config.claim_mode() == "label" then
    github().issue_add_label(repo, issue_number, claimed_label, 30)
    M.invalidate_entity_after_write(repo, "issue", issue_number)
    if C.verify_issue_claim(repo, issue_number, owner) then
      log_claim(dept, proposal_id, "claim-won", "label claim verified after add-label")
      return true
    end

    github().issue_remove_label(repo, issue_number, claimed_label, 30)
    M.invalidate_entity_after_write(repo, "issue", issue_number)
    log_claim(dept, proposal_id, "claim-lost", "label claim lost after add-label verification")
    return false
  end

  local assigned, assign_error = pcall(function()
    return github().issue_assign(repo, issue_number, owner, 30)
  end)
  if not assigned then
    if is_assign_permission_denied(assign_error) then
      local why = "assign permission-denied is permanent"
      log_terminal_skip(dept, proposal_id, "claim", issue_source_ref(repo, issue_number), "intake-skip-unclaimable", why)
      log_claim(dept, proposal_id, "skip-claim-permission-denied", why)
      return false
    end
    error(assign_error, 0)
  end
  M.invalidate_entity_after_write(repo, "issue", issue_number)
  if C.verify_issue_claim(repo, issue_number, owner) then
    log_claim(dept, proposal_id, "claim-won", "assignee claim verified after assign")
    return true
  end

  github().issue_unassign(repo, issue_number, owner, 30)
  M.invalidate_entity_after_write(repo, "issue", issue_number)
  log_claim(dept, proposal_id, "claim-lost", "assignee claim lost after assign verification")
  return false
end

function C.release_issue_claim_if_self(_M, dept, repo, issue_number, proposal_id, reason)
  local owner = C.claim_owner()
  local ownership = C.read_current_issue_ownership(repo, issue_number)
  local claim_state = C.issue_claim_state(
    ownership and ownership.assignees,
    owner,
    ownership and ownership.labels
  )
  if claim_state ~= "self" then
    log_claim(dept, proposal_id, "skip-release-not-self", "fresh ownership no longer shows the configured actor's claim")
    return false
  end

  if devloop_base.read_env("FKST_GITHUB_WRITE") ~= "1" then
    log_claim(dept, proposal_id, "dry-run-release", tostring(reason or "capacity reconciliation"))
    return true
  end

  if config.claim_mode() == "label" then
    github().issue_remove_label(repo, issue_number, claimed_label, 30)
  else
    github().issue_unassign(repo, issue_number, owner, 30)
  end
  github_proxy_entity_view.invalidate_entity_after_write(repo, "issue", issue_number)
  log_claim(dept, proposal_id, "claim-released", tostring(reason or "capacity reconciliation"))
  return true
end

function C.claim_required_payload(source_ref)
  local normalized = base_ids.normalize_source_ref(source_ref)
  local repo, issue_number = devloop_base.parse_issue_source_ref(normalized)
  if repo == nil or issue_number == nil then
    return nil
  end
  return {
    owner = C.claim_owner(),
    source_ref = normalized,
  }
end

function C.attach_issue_claim(payload, source_ref)
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
  if config.claim_mode() == "label" then
    return payload
  end
  payload.claim = C.claim_required_payload(source_ref or payload.source_ref)
  return payload
end

return C
