local devloop_base = require("devloop.base")
local parsers_misc = require("devloop.parsers.misc")
local base_ids = require("devloop.base_ids")
local queue = require("devloop.queue")
local saga = require("workflow.saga")
local devloop_logging = require("devloop.logging")
local admission_core = require("core.admission")
local admission_shared = require("core.admission_shared")
local replay_authorization = require("core.replay_authorization")

local spec = {
  consumes = { "github-proxy.github_issue_observed" },
  produces = { "devloop_intake_candidate" },
  fanout = { "github-proxy.github_issue_observed", "devloop_intake_candidate" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act_issue_observed(context, event)
  local entity = event.payload or {}
  devloop_logging.log_entry("replay_admission", event, "github-devloop/intake-observed", devloop_logging.payload_field(entity, "dedup_key"))
  if entity.type ~= "issue" then
    return
  end
  local repo, issue_number = devloop_base.parse_issue_source_ref(entity.source_ref)
  if repo == nil or issue_number == nil then
    devloop_logging.log_cas_decision("replay_admission", "unknown", { state = nil, version = nil }, "observed", "replay-candidate", "skip-foreign(source_ref)", "invalid issue source_ref")
    return
  end
  local proposal_id = base_ids.proposal_id(repo, issue_number)
  parsers_misc.assert_trusted_bot_configured()

  local terminal, precondition_reason, lineage = replay_authorization.terminal_precondition(entity.source_ref)
  if terminal == nil then
    admission_shared.reconcile_capacity(context, repo, proposal_id, "replay_admission")
    devloop_logging.log_cas_decision("replay_admission", proposal_id, { state = nil, version = nil }, "observed", "replay-candidate", "skip-" .. tostring(precondition_reason or "not-authorized"), "intake replay terminal precondition failed")
    return
  end

  local _, _, current = context.read_current_issue(entity.source_ref, entity.updated_at)
  devloop_logging.log_forged_markers("replay_admission", proposal_id, current.comments)
  local progress_visible = admission_shared.has_trusted_progress(current, proposal_id)
  local authorization, reason = replay_authorization.authorize(current, proposal_id, entity.source_ref, {
    has_trusted_progress = progress_visible,
    lineage = lineage,
    terminal = terminal,
  })
  if authorization == nil then
    admission_shared.reconcile_capacity(context, repo, proposal_id, "replay_admission")
    devloop_logging.log_cas_decision("replay_admission", proposal_id, { state = nil, version = nil }, "observed", "replay-candidate", "skip-" .. tostring(reason or "not-authorized"), "intake replay precondition failed")
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
      "replay_admission",
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
    local payload = admission_core.build_intake_replay_candidate(
      repo,
      admission_shared.issue_from_current(issue_number, current),
      authorization.terminal
    )
    devloop_logging.log_apply("replay_admission", proposal_id, nil, nil, { add = {}, remove = {} }, {
      "devloop_intake_candidate",
    })
    devloop_logging.log_raise("replay_admission", proposal_id, "devloop_intake_candidate", payload)
  end)
end

local function make_department(deps)
  local context = admission_shared.make_context(deps)
  local handlers = {
    ["github-proxy.github_issue_observed"] = function(event)
      return act_issue_observed(context, event)
    end,
  }
  local function act(event)
    local handled = queue.dispatch_consumed_queue("replay_admission", spec, event, handlers, "github-devloop-intake")
    if not handled then
      error("github-devloop-intake: consumed-queue-unrouted: " .. tostring(event and event.queue or ""))
    end
  end

  local previous_pipeline = _G.pipeline
  local department = saga.department(spec, {
    done = done,
    act = act,
    wrap = devloop_logging.wrap_pipeline_failure,
    name = "replay_admission",
  })
  department.pipeline = _G.pipeline
  _G.pipeline = previous_pipeline
  return department
end

local M = make_department()
M.make_department = make_department
_G.pipeline = M.pipeline

return M
