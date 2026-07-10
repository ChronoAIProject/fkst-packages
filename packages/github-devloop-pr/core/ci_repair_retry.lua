local ci_repair_attempts = require("core.ci_repair_attempts")
local fix_rounds = require("core.fix_rounds")
local timing_policy = require("core.timing_policy")
local trusted_marker_time = require("core.trusted_marker_time")
local ci_verdict = require("core.ci_verdict")
local devloop_state = require("devloop.state")
local payloads_builders = require("devloop.payloads.builders")
local requests_labels = require("devloop.requests.labels")
local requests_review = require("devloop.requests.review")
local entity_lib = require("devloop.entity")
local base_ids = require("devloop.base_ids")
local devloop_logging = require("devloop.logging")

local C = {}
local with_current_classification = ci_verdict.with_current_classification
local raise_admitted_round

local function admission_context(ctx, current_pr)
  return {
    dept = ctx.dept,
    from_state = "fixing",
    proposal_id = ctx.proposal_id,
    review_proposal_id = ctx.review_proposal_id,
    review_dedup_key = ctx.review_dedup_key,
    bound_head_sha = current_pr and current_pr.head_sha or ctx.reviewed_head_sha,
    pr_number = ctx.pr_number,
    source_ref = ctx.source_ref,
    reason = ctx.reason or "own-ci-red-repair-budget-exhausted",
  }
end

local function completed_attempt(ctx, state)
  return ci_repair_attempts.fact(ctx.comments, {
    proposal_id = ctx.proposal_id,
    pr_number = ctx.pr_number,
    version = state.version,
  })
end

local function retry_window(state, attempt, now_seconds)
  local state_entry = trusted_marker_time.state_entry(state, now_seconds)
  if state_entry.status == "policy-invalid" then
    return state_entry
  end
  local completion = trusted_marker_time.marker_after_state_entry(
    attempt.comment_created_at,
    state_entry,
    now_seconds
  )
  if completion.status == "policy-invalid" then
    return completion
  end
  local delay_seconds = devloop_state.version_fix_round(state.version)
    * timing_policy.liveness_poll_cadence_seconds()
  return {
    status = "valid",
    completed_seconds = completion.seconds,
    delay_seconds = delay_seconds,
    due_seconds = completion.seconds + delay_seconds,
    state_entry_seconds = state_entry.seconds,
    state_entry_source = state_entry.source,
  }
end

function C.evaluate(M, state, ctx)
  local attempt = completed_attempt(ctx, state)
  if attempt == nil then
    return { kind = "redrive" }
  end

  local current_seconds = tonumber(ctx.now_seconds)
  if current_seconds == nil then
    local invalid_ctx = admission_context(ctx)
    invalid_ctx.reason = "ci-repair-retry-policy-invalid"
    return fix_rounds.terminate_own_ci_policy_invalid(state, invalid_ctx)
  end
  local window = retry_window(state, attempt, current_seconds)
  if window.status == "policy-invalid" then
    local invalid_ctx = admission_context(ctx)
    invalid_ctx.reason = "ci-repair-retry-policy-invalid"
    return fix_rounds.terminate_own_ci_policy_invalid(state, invalid_ctx)
  end
  if current_seconds < window.due_seconds then
    return {
      kind = "defer",
      attempt = attempt,
      completed_seconds = window.completed_seconds,
      delay_seconds = window.delay_seconds,
      due_seconds = window.due_seconds,
    }
  end

  local decision, mismatch, current_pr = with_current_classification(
    ctx.repo,
    ctx.pr_number,
    ctx.reviewed_head_sha,
    function(classification)
      local admission = fix_rounds.admit_own_ci_continuation(state, classification, admission_context(ctx))
      if admission.kind == "not-own-ci" then
        return {
          kind = "reviewing",
          current_pr = admission.current_pr,
          reason = "own-CI gate no longer requires repair: " .. tostring(admission.reason),
        }
      end
      if admission.kind ~= "admit" then
        return admission
      end
      admission.attempt = attempt
      local apply = ctx.apply
      if type(apply) ~= "table" then
        error("github-devloop: ci-repair-retry-apply-missing: admitted retry requires its synchronous effect")
      end
      return {
        kind = "applied",
        result = raise_admitted_round(M, apply.dept, apply.issue, state, ctx.proposal_id,
          apply.link, apply.feedback, admission, apply.tools),
      }
    end,
    {
      dept = ctx.dept,
      proposal_id = ctx.proposal_id,
      error_class = "ci-repair-reobserve-failed: PR retry admission re-observation failed",
    }
  )
  if mismatch == "head-mismatch" then
    return {
      kind = "reviewing",
      current_pr = current_pr,
      reason = "PR head advanced after the completed CI repair round",
    }
  end
  return decision
end

local function liveness_comments(facts)
  if facts and facts.current_pr and type(facts.current_pr.comments) == "table" then
    return facts.current_pr.comments
  end
  if facts and facts.current and type(facts.current.comments) == "table" then
    return facts.current.comments
  end
  if facts and facts.snapshot and type(facts.snapshot.comments) == "table" then
    return facts.snapshot.comments
  end
  return {}
end

function C.resolve_liveness_hold(row, state, facts, now_seconds)
  local defer = row and row.defer or nil
  if type(defer) ~= "table"
    or defer.hold_fact ~= "ci-repair-attempt:v1"
    or defer.hold_resolver ~= "ci-repair-backoff" then
    return { status = "contract_invalid", reason = "unsupported durable hold declaration" }
  end
  local proposal_id = (facts and facts.proposal_id) or (state and state.proposal_id)
  local pr_number = facts and facts.link and facts.link.pr_number or nil
  if pr_number == nil then
    pr_number = select(2, require("devloop.base").parse_pr_source_ref(facts and facts.source_ref))
  end
  local attempt = completed_attempt({
    comments = liveness_comments(facts),
    proposal_id = proposal_id,
    pr_number = pr_number,
  }, state)
  if attempt == nil then
    return { status = "absent" }
  end
  local current_seconds = tonumber(now_seconds)
  if current_seconds == nil then
    return { status = "contract_invalid", reason = "durable hold requires an explicit clock" }
  end
  local window = retry_window(state, attempt, current_seconds)
  if window.status == "policy-invalid" then
    return {
      status = "contract_invalid",
      reason = "ci-repair-retry-policy-invalid: " .. tostring(window.reason),
    }
  end
  local status = current_seconds < window.due_seconds and "held" or "released"
  local fact_id = table.concat({
    "ci-repair-attempt:v1",
    tostring(proposal_id or ""),
    tostring(pr_number or ""),
    tostring(state and state.version or ""),
  }, ":")
  return {
    status = status,
    fact_family = "ci-repair-attempt:v1",
    fact_id = fact_id,
    due_ms = window.due_seconds * 1000,
    completed_seconds = window.completed_seconds,
    state_entry_source = window.state_entry_source,
    attempt = attempt,
  }
end

raise_admitted_round = function(M, dept, issue, state, proposal_id, link, feedback, decision, tools)
  local current_pr = decision.current_pr
  local source_ref = entity_lib.pr_source_ref(issue.repo, link.pr_number)
  local next_payload = payloads_builders.build_devloop_fixing_payload({
    proposal_id = proposal_id,
    impl_version = decision.version,
  }, link.pr_number, {
    review_proposal_id = feedback.review_proposal_id,
    review_dedup_key = feedback.review_dedup_key,
    reviewed_head_sha = current_pr.head_sha,
    blocking_gap = feedback.blocking_gap,
    gate_baseline_sha = current_pr.base_ref_oid,
    predecessor_set = feedback.predecessor_set,
    ci_failure_key = decision.ci_failure_key,
    gate_failure_excerpt = decision.reason,
  }, source_ref)
  local request = requests_review.build_merge_gate_fix_comment_request(M,
    issue.repo,
    issue.number,
    {
      proposal_id = proposal_id,
      pr_number = link.pr_number,
      version = state.version,
      review_proposal_id = feedback.review_proposal_id,
      review_dedup_key = feedback.review_dedup_key,
      reviewed_head_sha = current_pr.head_sha,
    },
    decision.version,
    decision.reason,
    current_pr.base_ref_oid,
    source_ref,
    feedback.predecessor_set,
    {
      blocking_gap = feedback.blocking_gap,
      gate_failure_excerpt = decision.reason,
      ci_failure_key = decision.ci_failure_key,
      current_head_sha = current_pr.head_sha,
    }
  )
  request.handoff.dedup_key = next_payload.dedup_key
  local effects = {
    { queue = "github-proxy.github_pr_comment_request", payload = request },
  }
  if issue.number ~= nil then
    table.insert(effects, {
      queue = "github-proxy.github_issue_label_request",
      payload = requests_labels.build_state_label_request(issue.repo, issue.number, "fixing", base_ids.dedup_key({
        "ci-repair",
        "label",
        "fixing",
        tostring(proposal_id),
        tostring(link.pr_number),
        tostring(decision.version),
      }), entity_lib.issue_source_ref(issue.repo, issue.number)),
    })
  end
  devloop_logging.log_cas_decision(dept, proposal_id, state, "fixing", "fixing", "applied(ci-repair-next-round)", decision.reason)
  return tools.raise_effects(dept, proposal_id, "fixing", decision.version, { add = {}, remove = {} }, effects)
end

return C
