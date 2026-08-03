local config = require("devloop.config")
local entity_view = require("devloop.github_proxy_entity_view")
local failure_triage_cap = require("failure_triage_cap")

local M = {}

local function log_resolution(fact, decision, action, mode, reason)
  log.info(table.concat({
    "github-devloop",
    "dept=observability",
    "tag=OUTPUT_OBLIGATION_RESOLUTION",
    "escalation=" .. tostring(fact and fact.escalation_issue_number or "unknown"),
    "proposal=" .. tostring(fact and fact.proposal_id or "unknown"),
    "decision=" .. tostring(decision or "none"),
    "action=" .. tostring(action or "skip"),
    "mode=" .. tostring(mode or "dry-run"),
    "reason=" .. tostring(reason or "none"),
  }, " "))
end

local function resolution_queue(request)
  if request.pr_number ~= nil then
    return "github-proxy.github_pr_comment_request"
  end
  return "github-proxy.github_issue_comment_request"
end

local function refresh_decision(core, github, fact, limits, deadline, consumer)
  if not core.observability_has_budget(deadline) then
    return nil, nil, nil, "deadline"
  end
  local timeout = core.observability_call_timeout(limits, deadline)
  if timeout < 1 then
    return nil, nil, nil, "deadline"
  end
  local source_issue = github.read_issue(fact.source_ref, {
    force_fresh = true,
    timeout = timeout,
    consumer = consumer .. "-source",
  })
  local linked_pr_snapshot = nil
  if tostring(source_issue and source_issue.state or ""):upper() == "OPEN" then
    linked_pr_snapshot = core.linked_pr_delegation_surface_snapshot(
      fact.source_repo,
      fact.proposal_id,
      source_issue.comments,
      {
        github = github,
        timeout = core.observability_call_timeout(limits, deadline),
      }
    )
  end
  if not core.observability_has_budget(deadline) then
    return nil, nil, nil, "deadline"
  end
  timeout = core.observability_call_timeout(limits, deadline)
  if timeout < 1 then
    return nil, nil, nil, "deadline"
  end
  local escalation_issue = github.read_issue(fact.escalation_source_ref, {
    force_fresh = true,
    timeout = timeout,
    consumer = consumer .. "-escalation",
  })
  local current_fact, current_reason = failure_triage_cap.classify_output_obligation_escalation_issue(
    escalation_issue,
    fact.escalation_repo,
    fact.escalation_issue_number
  )
  if current_fact == nil
    or current_fact.dedup_key ~= fact.dedup_key
    or current_fact.terminal_version ~= fact.terminal_version then
    return nil, nil, nil, current_reason or "escalation-changed"
  end
  local decision = failure_triage_cap.output_obligation_resolution_decision(
    current_fact,
    escalation_issue,
    source_issue,
    linked_pr_snapshot
  )
  return current_fact, decision, source_issue, nil
end

function M.reconcile(core, github, repo, entity, limits, deadline)
  local escalation_issue = type(entity) == "table" and entity.parent_issue or nil
  local fact = failure_triage_cap.classify_output_obligation_escalation_issue(
    escalation_issue,
    repo,
    type(entity) == "table" and entity.issue_number or nil
  )
  if fact == nil then
    return nil
  end
  if not core.observability_has_budget(deadline) then
    log_resolution(fact, nil, "defer", config.write_mode(), "deadline")
    return nil
  end
  if type(github) ~= "table" or type(github.read_issue) ~= "function" then
    error("github-devloop-ops: output-obligation-github-port-missing: observability resolution requires a GitHub adapter")
  end

  local current_fact, decision, _, refresh_reason = refresh_decision(
    core,
    github,
    fact,
    limits,
    deadline,
    "github-devloop-ops.output-obligation-resolution"
  )
  if current_fact == nil or decision == nil then
    log_resolution(fact, nil, "skip", config.write_mode(), refresh_reason or "refresh-failed")
    return nil
  end
  fact = current_fact

  local mode = config.write_mode()
  if decision.action == "command" or decision.action == "receipt" then
    log_resolution(fact, decision.decision, decision.action, mode, "fresh-authority")
    return {
      queue = resolution_queue(decision.request),
      payload = decision.request,
      fact = fact,
    }
  end
  if decision.action == "wait" or decision.action == "skip" then
    log_resolution(fact, decision.decision, decision.action, mode, decision.reason)
    return nil
  end
  if decision.action ~= "close" then
    error("github-devloop-ops: output-obligation-decision-invalid: resolution decision has no supported action")
  end
  if mode ~= "real" then
    log_resolution(fact, decision.decision, "close", mode, "receipt-visible")
    return nil
  end
  local close_fact, close_decision, _, close_reason = refresh_decision(
    core,
    github,
    fact,
    limits,
    deadline,
    "github-devloop-ops.output-obligation-resolution-close-guard"
  )
  if close_fact == nil
    or close_decision == nil
    or close_decision.decision ~= decision.decision
    or close_decision.action ~= "close" then
    log_resolution(
      close_fact or fact,
      close_decision and close_decision.decision or decision.decision,
      "skip",
      mode,
      close_reason or (close_decision and close_decision.reason) or "resolution-changed"
    )
    return nil
  end
  if not core.observability_has_budget(deadline) then
    log_resolution(close_fact, close_decision.decision, "defer", mode, "deadline-after-escalation-read")
    return nil
  end
  local timeout = core.observability_call_timeout(limits, deadline)
  if timeout < 1 then
    log_resolution(close_fact, close_decision.decision, "defer", mode, "deadline-after-escalation-read")
    return nil
  end
  fact = close_fact
  decision = close_decision
  local closed = github.issue_close(
    fact.escalation_repo,
    fact.escalation_issue_number,
    { kind = "completed" },
    timeout
  )
  if type(closed) ~= "table" or closed.exit_code ~= 0 then
    error("github-devloop-ops: output-obligation-close-failed: escalation issue close failed: "
      .. tostring(closed and closed.stderr or "missing result"))
  end
  entity_view.invalidate_entity_after_write(
    fact.escalation_repo,
    "issue",
    fact.escalation_issue_number
  )
  log_resolution(fact, decision.decision, "close", mode, "receipt-visible")
  return nil
end

return M
