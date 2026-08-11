local actions = require("core.materialize.actions")
local verified_satisfaction = require("core.verified_satisfaction")

local M = {}

function M.new(opts)
  local selected = opts or {}
  local deps = selected.deps or {}
  local child_observer = selected.child_observer
  local satisfaction_facts = selected.satisfaction_facts or {}
  local checkout_loaded = false
  local checkout = nil
  local predecessor_pr_loaded = false
  local cached_predecessor_pr = nil
  local matched_fact = nil
  local production_child_ref = selected.ledger
    and selected.ledger[verified_satisfaction.SLOT]
    and selected.ledger[verified_satisfaction.SLOT].child_ref
    or nil
  local delivered_by = nil

  local function current_checkout()
    if not checkout_loaded then
      checkout_loaded = true
      checkout = verified_satisfaction.current_checkout(deps)
    end
    return checkout
  end

  local function read_predecessor_pr(observer)
    local predecessor = selected.ledger and selected.ledger["walking-skeleton"] or nil
    if type(predecessor) == "table" and type(predecessor.child_ref) == "table" then
      return observer.merged_pr(predecessor.child_ref)
    end
    return nil
  end

  local function current_predecessor_pr()
    if not predecessor_pr_loaded then
      predecessor_pr_loaded = true
      cached_predecessor_pr = read_predecessor_pr(child_observer)
    end
    return cached_predecessor_pr
  end

  local function matching_context(child_ref, current_predecessor)
    return {
      origin = selected.origin,
      blueprint_digest = selected.blueprint_digest,
      child_issue = tostring(child_ref and child_ref.issue_number or ""),
      predecessor_pr = current_predecessor,
    }
  end

  local function fact_is_current(fact, child_ref)
    local fresh_checkout = verified_satisfaction.current_checkout(deps)
    if fresh_checkout == nil then
      return false
    end
    if type(selected.refresh_child_observer) ~= "function" then
      error("github-devloop-workflow: verified-satisfaction-observer-unavailable: "
        .. "commit validation requires a fresh child observer")
    end
    local fresh_observer = selected.refresh_child_observer()
    if type(fresh_observer) ~= "table" or type(fresh_observer.merged_pr) ~= "function" then
      error("github-devloop-workflow: verified-satisfaction-observer-invalid: "
        .. "commit validation requires a child observer with merged_pr")
    end
    return verified_satisfaction.matching_fact(
      { fact },
      matching_context(child_ref, read_predecessor_pr(fresh_observer)),
      fresh_checkout,
      deps
    ) ~= nil
  end

  if selected.workflow == verified_satisfaction.WORKFLOW
    and type(production_child_ref) == "table"
    and tostring(production_child_ref.slot or "") == verified_satisfaction.SLOT
    and #satisfaction_facts > 0 then
    matched_fact = verified_satisfaction.matching_fact(
      satisfaction_facts,
      matching_context(production_child_ref, current_predecessor_pr()),
      current_checkout(),
      deps
    )
    if matched_fact ~= nil then
      delivered_by = matched_fact.predecessor_commit
      selected.unit.guard(function()
        return fact_is_current(matched_fact, production_child_ref)
      end, "verified satisfaction binding changed before terminal publication")
    end
  end

  local coordinator = {}

  function coordinator.child_status(child_ref)
    if matched_fact ~= nil
      and tostring(child_ref and child_ref.slot or "") == verified_satisfaction.SLOT
      and tostring(child_ref and child_ref.issue_number or "") == matched_fact.child_issue then
      return "result_ready", {
        verified_satisfaction = true,
        predecessor_commit = matched_fact.predecessor_commit,
      }
    end
    return child_observer.status(child_ref)
  end

  function coordinator.decorate_decision(decision)
    if decision.action == "terminal"
      and decision.state == "done"
      and delivered_by ~= nil then
      decision.reason_code = verified_satisfaction.done_reason(delivered_by)
    end
  end

  function coordinator.stage_verification(decision, unit)
    if selected.workflow ~= verified_satisfaction.WORKFLOW
      or decision.slot ~= verified_satisfaction.SLOT
      or type(decision.child_ref) ~= "table" then
      return false
    end
    local verified = verified_satisfaction.verify({
      origin = selected.origin,
      workflow = selected.workflow,
      blueprint_digest = selected.blueprint_digest,
      slot = decision.slot,
      child_issue = tostring(decision.child_ref.issue_number or ""),
      refusal = child_observer.current_implementation_refusal(decision.child_ref),
      predecessor_pr = current_predecessor_pr(),
    }, deps)
    if verified == nil then
      return false
    end
    unit.guard(function()
      return fact_is_current(verified, decision.child_ref)
    end, "verified satisfaction binding changed before publication")
    unit.log_decision(
      selected.origin,
      "frontier",
      "verified-satisfaction",
      "applied(postcondition-verified)",
      "production slice delivered by " .. verified.predecessor_commit
    )
    unit.raise_request(
      selected.origin,
      "github-proxy.github_issue_comment_request",
      actions.verified_satisfaction_request(
        selected.repo,
        selected.issue_number,
        selected.origin,
        verified
      )
    )
    return true
  end

  return coordinator
end

return M
