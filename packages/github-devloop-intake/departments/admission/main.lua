local devloop_base = require("devloop.base")
local base_ids = require("devloop.base_ids")
local m_claims = require("devloop.claims")
local core = require("core")
local queue = require("devloop.queue")
local saga = require("workflow.saga")
local m_facts = require("devloop.markers.facts")
local devloop_logging = require("devloop.logging")
local config = require("devloop.config")
local admission_core = require("core.admission")
local admission_shared = require("core.admission_shared")
local premise_correction = require("devloop.premise_correction")

local spec = {
  consumes = { "github-proxy.github_entity_changed" },
  produces = {
    "devloop_intake_candidate",
    "github-proxy.github_issue_create_request",
  },
  fanout = { "github-proxy.github_entity_changed", "devloop_intake_candidate" },
  stall_window = "30s",
}

local reconcile_capacity = admission_shared.reconcile_capacity

local function claim_with_capacity(context, authorize, repo, issue_number, current, proposal_id, admission, detail)
  local granted, reason = authorize(repo, issue_number, current, proposal_id)
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

local function settled_claim_admission(context, repo, current, poll_key)
  return context.claims.claim_admission_precheck(
    current,
    context.claims.claim_admission_inputs(current, repo, poll_key)
  )
end

local function done(_event)
  return false
end

local issue_from_current = admission_shared.issue_from_current

local function initial_claim_is_in_milestone_scope(context, repo, current, poll_key)
  local admission, detail = settled_claim_admission(context, repo, current, poll_key)
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
  local poll_key = m_claims.claim_admission_poll_epoch(event)

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
  local intake_fact = m_facts.intake_decision_fact(current.comments, proposal_id)
  local correction = premise_correction.matching_correction_fact(current.comments, intake_fact)
  if intake_fact ~= nil and correction == nil then
    reconcile_capacity(context, repo, proposal_id)
    devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "entity", "candidate", "skip-intake-decision", "trusted intake decision marker is already visible")
    return
  end
  local in_milestone_scope, claim_admission, claim_detail = initial_claim_is_in_milestone_scope(
    context,
    repo,
    current,
    poll_key
  )
  if not in_milestone_scope then
    reconcile_capacity(context, repo, proposal_id)
    devloop_logging.log_cas_decision("admission", proposal_id, { state = nil, version = nil }, "entity", "candidate", "skip-outside-intake-milestone", "fresh issue milestone=" .. tostring(current.milestone_number or "none") .. " is outside configured intake scope")
    return
  end
  local epoch_current = context.claims.with_current_claim_admission_epoch(claim_detail, function()
    if not claim_with_capacity(
      context,
      context.capacity.authorize,
      repo,
      issue_number,
      current,
      proposal_id,
      claim_admission,
      claim_detail
    ) then
      return
    end

    local payload = correction ~= nil
      and admission_core.build_premise_correction_candidate(repo, issue, correction)
      or core.build_intake_admission_candidate(repo, issue, now())
    devloop_logging.log_apply("admission", proposal_id, nil, nil, { add = {}, remove = {} }, {
      "devloop_intake_candidate",
    })
    devloop_logging.log_raise("admission", proposal_id, "devloop_intake_candidate", payload)
  end)
  if not epoch_current then
    devloop_logging.log_cas_decision(
      "admission",
      proposal_id,
      { state = nil, version = nil },
      "peer-activity-epoch",
      "candidate",
      "skip-stale",
      "peer activity authorization epoch is stale before admission effects"
    )
  end
end

local function act_entity_changed(context, event)
  local entity = event.payload or {}
  if entity.type ~= "issue" then
    return
  end
  admit_issue_event(context, event, entity)
end

local function make_department(deps)
  local context = admission_shared.make_context(deps)
  local handlers = {
    ["github-proxy.github_entity_changed"] = function(event)
      return act_entity_changed(context, event)
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
