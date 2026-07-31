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

  local source_issue = github.read_issue(fact.source_ref, {
    force_fresh = true,
    timeout = core.observability_call_timeout(limits, deadline),
    consumer = "github-devloop-ops.output-obligation-resolution",
  })
  local decision = failure_triage_cap.output_obligation_resolution_decision(
    fact,
    escalation_issue,
    source_issue
  )
  if decision.decision ~= "source-closed" then
    return nil
  end

  local mode = config.write_mode()
  if decision.action == "receipt" then
    log_resolution(fact, decision.decision, "receipt", mode, "closed-source")
    return {
      queue = "github-proxy.github_issue_comment_request",
      payload = decision.request,
      fact = fact,
    }
  end
  if decision.action ~= "close" then
    error("github-devloop-ops: output-obligation-decision-invalid: source-closed decision has no supported action")
  end
  if mode ~= "real" then
    log_resolution(fact, decision.decision, "close", mode, "receipt-visible")
    return nil
  end
  if not core.observability_has_budget(deadline) then
    log_resolution(fact, decision.decision, "defer", mode, "deadline-after-source-read")
    return nil
  end
  local timeout = core.observability_call_timeout(limits, deadline)
  if timeout < 1 then
    log_resolution(fact, decision.decision, "defer", mode, "deadline-after-source-read")
    return nil
  end
  local current_escalation = github.read_issue(fact.escalation_source_ref, {
    force_fresh = true,
    timeout = timeout,
    consumer = "github-devloop-ops.output-obligation-resolution-close-guard",
  })
  local current_fact, current_reason = failure_triage_cap.classify_output_obligation_escalation_issue(
    current_escalation,
    fact.escalation_repo,
    fact.escalation_issue_number
  )
  if current_fact == nil then
    log_resolution(fact, decision.decision, "skip", mode, current_reason or "escalation-changed")
    return nil
  end
  local current_decision = failure_triage_cap.output_obligation_resolution_decision(
    current_fact,
    current_escalation,
    source_issue
  )
  if current_decision.decision ~= "source-closed" or current_decision.action ~= "close" then
    log_resolution(current_fact, current_decision.decision, "skip", mode, current_decision.reason or "escalation-changed")
    return nil
  end
  if not core.observability_has_budget(deadline) then
    log_resolution(current_fact, current_decision.decision, "defer", mode, "deadline-after-escalation-read")
    return nil
  end
  timeout = core.observability_call_timeout(limits, deadline)
  if timeout < 1 then
    log_resolution(current_fact, current_decision.decision, "defer", mode, "deadline-after-escalation-read")
    return nil
  end
  fact = current_fact
  decision = current_decision
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
