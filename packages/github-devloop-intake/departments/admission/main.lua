local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local m_claims = require("devloop.claims")
local parsers_issue = require("devloop.parsers.issue")
local core = require("core")
local operator_commands = require("devloop.operator_commands")
local queue = require("devloop.queue")
local saga = require("workflow.saga")
local m_facts = require("devloop.markers.facts")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local config = require("devloop.config")
local entity_lib = require("devloop.entity")
local admission_core = require("core.admission")
local intake_capacity = require("core.intake_capacity")
local replay_authorization = require("core.replay_authorization")

local spec = {
  consumes = { "github-proxy.github_entity_changed", "github-proxy.github_issue_observed" },
  produces = {
    "devloop_intake_candidate",
    "github-proxy.github_issue_comment_request",
    "github-proxy.github_issue_create_request",
  },
  fanout = { "github-proxy.github_entity_changed", "github-proxy.github_issue_observed", "devloop_intake_candidate" },
  stall_window = "30s",
}

local function raise_reintake_refusal(repo, issue_number, proposal_id, command, reason, source_ref)
  local request = operator_commands.build_operator_issue_command_refusal_request(repo,
    tostring(issue_number),
    command,
    reason,
    source_ref
  )
  devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "reintake-command", "candidate", "refused(" .. tostring(reason) .. ")", "operator reintake precondition failed")
  devloop_logging.log_raise("admission", proposal_id, "github-proxy.github_issue_comment_request", request)
end

local function reconcile_capacity(context, repo, proposal_id)
  local reconciled, reason = context.capacity.reconcile(repo, proposal_id)
  devloop_logging.log_cas_decision(
    "admission",
    proposal_id,
    { state = nil, version = nil },
    "capacity-grant",
    "capacity-grant",
    reconciled and "reconciled" or "deferred",
    reason
  )
  return reconciled
end

local function claim_with_capacity(context, repo, issue_number, current, proposal_id, admission, detail)
  local granted, reason = context.capacity.authorize(repo, issue_number, current, proposal_id)
  if not granted then
    devloop_logging.log_cas_decision(
      "admission",
      proposal_id,
      { state = nil, version = nil },
      "capacity-grant",
      "candidate",
      "skip-capacity",
      reason
    )
    return false
  end
  if context.claims.claim_issue_for_management(
    core,
    "admission",
    repo,
    issue_number,
    current,
    proposal_id,
    admission,
    detail
  ) then
    return true
  end
  if not context.capacity.relinquish(repo, issue_number, proposal_id) then
    error("github-devloop-intake: capacity-relinquish-contended: failed claim grant remains remotely authorized")
  end
  return false
end

local function handle_pending_reintake(context, repo, issue, current, proposal_id, source_ref)
  local command = core.pending_reintake_command(current.comments)
  if command == nil then
    return false
  end
  reconcile_capacity(context, repo, proposal_id)
  if current.state ~= "OPEN" then
    raise_reintake_refusal(repo, issue.number, proposal_id, command, "reintake requires an open issue", source_ref)
    return true
  end
  if not m_facts.has_intake_decision_marker(current.comments, proposal_id) then
    raise_reintake_refusal(repo, issue.number, proposal_id, command, "reintake requires an existing intake decision", source_ref)
    return true
  end
  if devloop_base.is_intake_held(current.labels) then
    devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "reintake-command", "candidate", "skip-held", "fkst-dev:hold label is present")
    return true
  end
  if core.reintake_has_active_devloop_state(current.labels, current.comments, proposal_id) then
    raise_reintake_refusal(repo, issue.number, proposal_id, command, "reintake requires terminal blocked or no active devloop state; use rereview, reready, or reimplement for recoverable active states", source_ref)
    return true
  end
  if not claim_with_capacity(context, repo, issue.number, current, proposal_id) then
    return true
  end
  local payload = core.build_intake_admission_candidate(repo, issue, command, now(), current.comments)
  devloop_logging.log_apply("admission", proposal_id, nil, nil, { add = {}, remove = {} }, {
    "devloop_intake_candidate",
  })
  devloop_logging.log_raise("admission", proposal_id, "devloop_intake_candidate", payload)
  return true
end

local function done(_event)
  return false
end

local function current_issue_from_source_ref(source_ref, updated_at)
  local repo, issue_number = devloop_base.parse_issue_source_ref(source_ref)
  if repo == nil or issue_number == nil then
    return nil, nil, nil, "invalid issue source_ref"
  end
  local view = devloop_commands.gh_issue_view_intake_judge(repo, issue_number, 30)
  if view.exit_code ~= 0 then
    error("github-devloop-intake: gh-issue-admission-view-failed: gh issue admission view failed: " .. tostring(view.stderr))
  end
  local current = parsers_issue.parse_issue_view_intake_judge(core, view.stdout)
  current.updated_at = current.updated_at or updated_at
  current.number = issue_number
  return repo, issue_number, current, nil
end

local function has_trusted_progress(current, proposal_id)
  if core.should_skip_known_intake_issue(current.labels) then
    return true, "active devloop label is visible"
  end
  if m_facts.has_intake_decision_marker(current.comments, proposal_id) then
    return true, "trusted intake decision marker is already visible"
  end
  if m_facts.has_state_marker(current.comments, proposal_id) then
    return true, "trusted state marker is already visible"
  end
  return false, nil
end

local function issue_from_current(issue_number, current)
  return {
    number = issue_number,
    title = current.title,
    body = current.body,
    updated_at = current.updated_at,
  }
end

local function initial_claim_is_in_milestone_scope(context, repo, current)
  local admission, detail = context.claims.claim_admission_precheck(
    current,
    context.claims.claim_admission_inputs(current, repo)
  )
  if admission ~= "needs-claim" then
    return true, admission, detail
  end
  local milestones = config.intake_milestone_numbers()
  return milestones == nil or milestones[current.milestone_number] == true, admission, detail
end

local function admit_issue_event(context, event, entity)
  entity = entity or event.payload or {}
  devloop_logging.log_entry("admission", event, "github-devloop/intake", devloop_logging.payload_field(entity, "dedup_key"))
  local repo, issue_number = devloop_base.parse_issue_source_ref(entity.source_ref)
  if repo == nil or issue_number == nil then
    devloop_logging.log_cas_decision("admission", "unknown", { state = nil, version = nil }, "entity", "candidate", "skip-foreign(source_ref)", "invalid issue source_ref")
    return
  end
  local proposal_id = base_ids.proposal_id(repo, issue_number)
  devloop_base.assert_trusted_bot_configured()

  local _, _, current = context.read_current_issue(entity.source_ref, entity.updated_at)

  devloop_logging.log_forged_markers("admission", proposal_id, current.comments)
  local issue = issue_from_current(issue_number, current)

  if handle_pending_reintake(context, repo, issue, current, proposal_id, entity.source_ref) then
    return
  end
  if current.state ~= "OPEN" then
    reconcile_capacity(context, repo, proposal_id)
    devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "entity", "candidate", "skip-closed", "fresh issue is not open")
    return
  end
  if core.should_skip_known_intake_issue(current.labels) then
    reconcile_capacity(context, repo, proposal_id)
    devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "entity", "candidate", "skip-known-state", "fresh issue labels show an active devloop state")
    return
  end
  if m_facts.has_intake_decision_marker(current.comments, proposal_id) then
    reconcile_capacity(context, repo, proposal_id)
    devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "entity", "candidate", "skip-intake-decision", "trusted intake decision marker is already visible")
    return
  end
  local in_milestone_scope, claim_admission, claim_detail = initial_claim_is_in_milestone_scope(context, repo, current)
  if not in_milestone_scope then
    reconcile_capacity(context, repo, proposal_id)
    devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "entity", "candidate", "skip-outside-intake-milestone", "fresh issue milestone=" .. tostring(current.milestone_number or "none") .. " is outside configured intake scope")
    return
  end
  if not claim_with_capacity(context, repo, issue_number, current, proposal_id, claim_admission, claim_detail) then
    return
  end

  local payload = core.build_intake_admission_candidate(repo, issue, nil, now())
  devloop_logging.log_apply("admission", proposal_id, nil, nil, { add = {}, remove = {} }, {
    "devloop_intake_candidate",
  })
  devloop_logging.log_raise("admission", proposal_id, "devloop_intake_candidate", payload)
end

local function act_issue_observed(context, event)
  local entity = event.payload or {}
  devloop_logging.log_entry("admission", event, "github-devloop/intake-observed", devloop_logging.payload_field(entity, "dedup_key"))
  if entity.type ~= "issue" then
    return
  end
  local repo, issue_number = devloop_base.parse_issue_source_ref(entity.source_ref)
  if repo == nil or issue_number == nil then
    devloop_logging.log_cas_decision("admission", "unknown", { state = nil, version = nil }, "observed", "candidate", "skip-foreign(source_ref)", "invalid issue source_ref")
    return
  end
  local proposal_id = base_ids.proposal_id(repo, issue_number)
  devloop_base.assert_trusted_bot_configured()

  local lock_key = entity_lib.observe_lock_key(repo, issue_number)
  with_lock(lock_key, function()
    local terminal, precondition_reason, observe_snapshot = replay_authorization.terminal_precondition(entity.source_ref)
    if terminal == nil then
      reconcile_capacity(context, repo, proposal_id)
      devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "observed", "replay-candidate", "skip-" .. tostring(precondition_reason or "not-authorized"), "intake replay terminal precondition failed")
      return
    end

    local _, _, current = context.read_current_issue(entity.source_ref, entity.updated_at)
    devloop_logging.log_forged_markers("admission", proposal_id, current.comments)
    local progress_visible = has_trusted_progress(current, proposal_id)
    local authorization, reason = replay_authorization.authorize(current, proposal_id, entity.source_ref, {
      has_trusted_progress = progress_visible,
      observe_snapshot = observe_snapshot,
      terminal = terminal,
    })
    if authorization == nil then
      reconcile_capacity(context, repo, proposal_id)
      devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "observed", "replay-candidate", "skip-" .. tostring(reason or "not-authorized"), "intake replay precondition failed")
      return
    end

    local capacity_granted, capacity_reason = context.capacity.authorize(
      repo,
      issue_number,
      current,
      proposal_id
    )
    if not capacity_granted then
      devloop_logging.log_cas_decision(
        "admission",
        proposal_id,
        { state = nil, version = nil },
        "observed",
        "replay-candidate",
        "skip-capacity",
        capacity_reason
      )
      return
    end

    once(authorization.once_key, function()
      local payload = admission_core.build_intake_replay_candidate(repo, issue_from_current(issue_number, current), authorization.terminal)
      devloop_logging.log_apply("admission", proposal_id, nil, nil, { add = {}, remove = {} }, {
        "devloop_intake_candidate",
      })
      devloop_logging.log_raise("admission", proposal_id, "devloop_intake_candidate", payload)
    end)
  end)
end

local function act_entity_changed(context, event)
  local entity = event.payload or {}
  if entity.type ~= "issue" then
    return
  end
  admit_issue_event(context, event, entity)
end

local function make_department(deps)
  local selected = deps or {}
  local context = {
    capacity = selected.capacity or intake_capacity.production(core),
    claims = selected.claims or m_claims,
    read_current_issue = selected.read_current_issue or current_issue_from_source_ref,
  }
  local handlers = {
    ["github-proxy.github_entity_changed"] = function(event)
      return act_entity_changed(context, event)
    end,
    ["github-proxy.github_issue_observed"] = function(event)
      return act_issue_observed(context, event)
    end,
  }
  local function act(event)
    local handled = queue.dispatch_consumed_queue("admission", spec, event, handlers, "github-devloop-intake")
    if not handled then
      error("github-devloop-intake: consumed-queue-unrouted: " .. tostring(event and event.queue or ""))
    end
  end

  local previous_pipeline = _G.pipeline
  local department = saga.department(spec, {
    done = done,
    act = act,
    wrap = devloop_logging.wrap_pipeline_failure,
    name = "admission",
  })
  department.pipeline = _G.pipeline
  _G.pipeline = previous_pipeline
  return department
end

local M = make_department()
M.make_department = make_department
_G.pipeline = M.pipeline

return M
