local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local C = {}
local github_handle = nil
local github_factory = require("devloop.github_factory")
local error_facts = require("contract.error_facts")
local contract_time = require("contract.time")
local config = require("devloop.config")
local claim_carriers = require("devloop.claim_carriers")
local entity_list_cache = require("devloop.entity_list_cache")
local github_author_policy = require("devloop.github_author_policy")
local github_view = require("forge.github_view")
local github_proxy_entity_view = require("devloop.github_proxy_entity_view")
local devloop_logging = require("devloop.logging")
local parsers_shared = require("devloop.parsers.shared")
local forks = require("devloop.forks")
local restart_metadata = require("devloop.restart_metadata")

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
    error("github-devloop: github-adapter-missing-exec-argv: GitHub adapter requires exec_argv")
  end
  github_handle = github_factory.production_handle()
  return github_handle
end

C.issue_author_login = parsers_shared.issue_author_login
C.assignee_logins = parsers_shared.assignee_logins
C.claim_owner = github_author_policy.claim_owner
C.managed_bot_logins = github_author_policy.managed_bot_logins
C.is_managed_bot_login = github_author_policy.is_managed_bot_login
C.observed_state_marker_managed_bot_logins = github_author_policy.observed_state_marker_managed_bot_logins

function C.repo_scoped_observed_managed_bot_logins(repo, trusted_author_policy, owner, github_handle, poll_key)
  if poll_key == nil or tostring(poll_key) == "" then
    error("github-devloop: peer-snapshot-poll-epoch-missing: peer snapshot poll epoch must be non-empty")
  end
  if type(trusted_author_policy) ~= "table" or repo == nil or tostring(repo) == "" then
    return {}
  end
  return github_author_policy.repo_scoped_observed_managed_bot_logins(
    repo,
    trusted_author_policy,
    owner,
    github_handle or github(),
    poll_key
  )
end

function C.claimed_label()
  return claim_carriers.active_label(config.claim_label_exclusive(), C.claim_owner())
end

local function merge_managed_bot_logins(managed, observed)
  for login, allowed in pairs(observed) do
    if allowed == true then
      managed[login] = true
    end
  end
end

function C.claim_mode_active()
  return config.claim_mode()
end

function C.issue_claim_state(assignees, owner, labels)
  local mode = config.claim_mode()
  return claim_carriers.classify(
    mode,
    C.assignee_logins(assignees),
    owner,
    labels,
    mode == "label" and C.claimed_label() or nil,
    mode == "label" and C.managed_bot_logins() or nil
  )
end

local function issue_ownership_decision(ownership, owner)
  if type(ownership) ~= "table" then
    return { owned = false, claim_state = nil }
  end
  local claim_state = C.issue_claim_state(ownership.assignees, owner, ownership.labels)
  if claim_state == "self" then
    return { owned = true, claim_state = claim_state }
  end
  if claim_state ~= "unassigned" then
    return { owned = false, claim_state = claim_state }
  end
  -- Unassigned+self-author is intentional for fork-and-block isolation: a different bot login sees author!=self and skips.
  local author = C.issue_author_login(ownership)
  if author == nil then
    return { owned = false, claim_state = claim_state }
  end
  return { owned = devloop_base.strip_bot_login_suffix(author) == tostring(owner or ""), claim_state = claim_state }
end

function C.is_self_owned_issue(ownership, owner)
  return issue_ownership_decision(ownership, owner).owned
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
  local fields = "assignees,author,labels"
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

function C.pr_review_issue_claim_decision(dept, repo, issue_number, current_issue, proposal_id)
  if issue_number == nil then
    log_claim(dept, proposal_id, "skip-not-owned", "backing issue is absent")
    return { owned = false, claim_state = nil }
  end
  local owner = C.claim_owner()
  local ownership = nil
  local mode = config.claim_mode()
  local current_usable = type(current_issue) == "table"
    and type(current_issue.assignees) == "table"
    and type(current_issue.labels) == "table"
  if mode ~= "label" then
    current_usable = current_usable and C.issue_author_login(current_issue) ~= nil
  end
  if current_usable then
    ownership = current_issue
  else
    ownership = C.read_current_issue_ownership(repo, issue_number)
  end
  local decision = issue_ownership_decision(ownership, owner)
  if decision.owned then
    return decision
  end
  if decision.claim_state == "other" then
    log_claim(dept, proposal_id, "skip-claimed-by-other", "backing issue assignee claim is held by another login")
  else
    log_claim(dept, proposal_id, "skip-not-owned", "backing issue is not self-owned")
  end
  return decision
end

function C.verify_pr_review_issue_claim(dept, repo, issue_number, current_issue, proposal_id)
  return C.pr_review_issue_claim_decision(dept, repo, issue_number, current_issue, proposal_id).owned
end

function C.fork_grace_seconds(exec)
  local raw = devloop_base.read_env("FKST_DEVLOOP_FORK_GRACE_HOURS", exec)
  raw = strings.trim(raw or "")
  if raw == "" then
    return 3 * 60 * 60
  end
  local hours = tonumber(raw)
  if hours == nil or hours <= 0 or hours > 168 then
    error("github-devloop: fork-grace-hours-invalid: invalid FKST_DEVLOOP_FORK_GRACE_HOURS")
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

function C.claim_admission_inputs(current, repo, poll_key)
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
  local peer_discovery_error = nil
  local peer_snapshot_provenance = nil
  if claim_mode ~= "label" and author ~= nil and author ~= "" and author ~= owner then
    managed = C.managed_bot_logins()
    if not C.is_managed_bot_login(author, managed) then
      local github_handle = github()
      trusted_author_policy = github_author_policy.from_handle_policy(github_handle)
      merge_managed_bot_logins(
        managed,
        C.observed_state_marker_managed_bot_logins(current, trusted_author_policy, owner)
      )
      if not C.is_managed_bot_login(author, managed)
        and github_author_policy.is_authorized(trusted_author_policy, author)
        and status ~= "self" then
        local peer_repo = repo or (current and current.repo)
        if poll_key == nil or tostring(poll_key) == "" then
          peer_discovery_error = "peer-activity-poll-epoch-unavailable"
        elseif peer_repo == nil or tostring(peer_repo) == "" then
          peer_discovery_error = "peer-activity-repo-unavailable"
        else
          peer_snapshot_provenance = {
            repo = peer_repo,
            poll_epoch = tostring(poll_key),
          }
          local observed, unavailable_reason = C.repo_scoped_observed_managed_bot_logins(
            peer_snapshot_provenance.repo,
            trusted_author_policy,
            owner,
            github_handle,
            peer_snapshot_provenance.poll_epoch
          )
          if observed == nil then
            peer_discovery_error = unavailable_reason or "peer-activity-unavailable"
          else
            merge_managed_bot_logins(managed, observed)
          end
        end
      end
    end
  end
  return {
    owner = owner,
    status = status,
    claim_mode = claim_mode,
    managed = managed,
    trusted_author_policy = trusted_author_policy,
    peer_discovery_error = peer_discovery_error,
    peer_snapshot_provenance = peer_snapshot_provenance,
  }
end

function C.claim_admission_poll_epoch(event)
  return entity_list_cache.entity_list_poll_epoch(event)
end

local function claim_admission_peer_snapshot_provenance(detail)
  if type(detail) ~= "table" then
    return nil
  end
  local provenance = detail.peer_snapshot_provenance
  if provenance == nil then
    return nil
  end
  if type(provenance) ~= "table"
    or provenance.repo == nil
    or tostring(provenance.repo) == ""
    or provenance.poll_epoch == nil
    or tostring(provenance.poll_epoch) == "" then
    error("github-devloop: peer-snapshot-provenance-invalid: peer snapshot provenance requires repo and poll epoch")
  end
  return provenance
end

function C.claim_admission_epoch_is_current(detail)
  local provenance = claim_admission_peer_snapshot_provenance(detail)
  if provenance == nil then
    return true
  end
  return entity_list_cache.poll_epoch_is_current(
    provenance.repo,
    provenance.poll_epoch
  )
end

function C.with_current_claim_admission_epoch(detail, fn)
  if type(fn) ~= "function" then
    error("github-devloop: claim-admission-guard-invalid: claim admission epoch guard requires a function")
  end
  local provenance = claim_admission_peer_snapshot_provenance(detail)
  if provenance == nil then
    return true, fn()
  end
  return entity_list_cache.with_current_poll_epoch(
    provenance.repo,
    provenance.poll_epoch,
    fn
  )
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
    peer_snapshot_provenance = inputs.peer_snapshot_provenance,
  }
  local function settle(decision, action, reason)
    detail.action = action
    detail.reason = reason
    return decision, detail
  end
  if inputs.status == "other" then
    return settle("other", "skip-claimed-by-other", "issue assignee claim is held by another login")
  end

  if inputs.claim_mode ~= "label" then
    if author == nil or author == "" then
      return settle("denied", "skip-fork-author-unknown", "issue author is missing or unknown")
    end
    if author ~= inputs.owner then
      if not C.claim_admission_epoch_is_current(inputs) then
        return settle("denied", "skip-peer-discovery-stale-epoch", "peer activity authorization epoch is stale")
      end
      if inputs.peer_discovery_error ~= nil then
        return settle("denied", "skip-peer-discovery-unavailable", tostring(inputs.peer_discovery_error))
      end
      if C.is_managed_bot_login(author, inputs.managed) then
        if inputs.status == "self" then
          return "held", detail
        end
        return settle(
          "denied",
          "skip-fork-peer-bot",
          "other-authored unassigned issue belongs to a managed bot login"
        )
      end
      if not github_author_policy.is_authorized(inputs.trusted_author_policy, author) then
        return settle(
          "denied",
          "skip-non-whitelisted-author",
          "other-authored issue author is not authorized for GitHub content"
        )
      end
    end
  end
  if inputs.status == "self" then
    return "held", detail
  end
  if author == nil or author == "" then
    return settle("denied", "skip-fork-author-unknown", "issue author is missing or unknown")
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
    error("github-devloop: claim-admission-decision-invalid: invalid claim admission decision")
  end
  if not C.claim_admission_epoch_is_current(detail) then
    log_claim(dept, proposal_id, "skip-peer-discovery-stale-epoch", "peer activity authorization epoch is stale")
    return false
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
    local dedup_key = forks.fork_issue_dedup_key(repo, issue_number)
    if forks.has_trusted_issue_create_parent_marker(M, current and current.comments, dedup_key, owner, managed) then
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
    current = forks.rederive_issue_state(M, repo, issue_number)
    local request, request_reason = forks.build_fork_issue_create_request(M, repo, issue_number, current, base_ids.issue_source_ref(repo, issue_number))
    if request == nil then
      log_claim(dept, proposal_id, "skip-fork-" .. tostring(request_reason or "invalid"), "fork request could not be built from current issue")
      return false
    end
    if forks.has_trusted_issue_create_parent_marker(M, current and current.comments, request.dedup_key, owner, managed) then
      log_claim(dept, proposal_id, "fork-present", "trusted fork issue-create ledger marker already exists")
      return false
    end
    if not C.claim_admission_epoch_is_current(detail) then
      log_claim(dept, proposal_id, "skip-peer-discovery-stale-epoch", "peer activity authorization epoch became stale before fork")
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

  if not C.claim_admission_epoch_is_current(detail) then
    log_claim(dept, proposal_id, "skip-peer-discovery-stale-epoch", "peer activity authorization epoch became stale before claim")
    return false
  end

  if config.claim_mode() == "label" then
    local active_label = C.claimed_label()
    github().issue_add_label(repo, issue_number, active_label, 30)
    M.invalidate_entity_after_write(repo, "issue", issue_number)
    if C.verify_issue_claim(repo, issue_number, owner) then
      log_claim(dept, proposal_id, "claim-won", "label claim verified after add-label")
      return true
    end

    github().issue_remove_label(repo, issue_number, active_label, 30)
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
  local active_label = config.claim_mode() == "label" and C.claimed_label() or nil
  local claim_is_self = active_label ~= nil
    and restart_metadata.has_label(ownership and ownership.labels, active_label)
    or active_label == nil
      and claim_carriers.classify_assignees(C.assignee_logins(ownership and ownership.assignees), owner) == "self"
  if not claim_is_self then
    log_claim(dept, proposal_id, "skip-release-not-self", "fresh ownership no longer shows the configured actor's claim")
    return false
  end

  if devloop_base.read_env("FKST_GITHUB_WRITE") ~= "1" then
    log_claim(dept, proposal_id, "dry-run-release", tostring(reason or "capacity reconciliation"))
    return true
  end

  if active_label ~= nil then
    github().issue_remove_label(repo, issue_number, active_label, 30)
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
  local claim = {
    owner = C.claim_owner(),
    source_ref = normalized,
  }
  if config.claim_mode() == "label" then
    claim.label = C.claimed_label()
  end
  return claim
end

function C.attach_issue_claim(payload, source_ref)
  if type(payload) ~= "table" then
    return payload
  end
  payload.claim = C.claim_required_payload(source_ref or payload.source_ref)
  return payload
end

return C
