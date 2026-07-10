local entity_lib = require("devloop.entity")
local requests_labels = require("devloop.requests.labels")
local requests_review = require("devloop.requests.review")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local ci_verdict = require("core.ci_verdict")
local fix_rounds = require("core.fix_rounds")
local with_current_classification = ci_verdict.with_current_classification

local C = {}

function C.make(deps)
local kernel = assert(deps and deps.kernel, "github-devloop: speculative refix kernel is required")
local raise_reviewing = assert(deps and deps.raise_reviewing, "github-devloop: speculative refix reviewing router is required")
local M = {}

function M.raise(repo, issue_number, fix, current_state, current_predecessor_set, reason)
  local function raise_generation(next_version, current_ci_failure_key, current_gate_reason)
  local merge_ready = {
    proposal_id = fix.proposal_id,
    pr_number = fix.pr_number,
    version = devloop_state._strip_latest_fix_version_suffix(fix.version),
    review_proposal_id = fix.review_proposal_id,
    review_dedup_key = fix.review_dedup_key,
    reviewed_head_sha = fix.reviewed_head_sha,
    dedup_key = fix.dedup_key,
  }
  local comment_request = requests_review.build_merge_gate_fix_comment_request(kernel,
    repo,
    issue_number,
    merge_ready,
    next_version,
    current_gate_reason,
    fix.gate_baseline_sha,
    fix.source_ref,
    current_predecessor_set,
    {
      blocking_gap = fix.blocking_gap,
      gate_failure_excerpt = fix.gate_failure_excerpt,
      preserve_nil_gate_failure_excerpt = true,
      repair_input = fix.repair_input,
      ci_failure_key = current_ci_failure_key,
    }
  )
  local label_request = issue_number ~= nil and requests_labels.build_state_label_request(repo,
    issue_number,
    "fixing",
    fix.dedup_key .. "/label/refix/" .. tostring(devloop_state.version_fix_round(next_version)),
    entity_lib.issue_source_ref(repo, issue_number)
  ) or nil
  local add_labels, remove_labels = devloop_state.state_label_changes("fixing")
  devloop_logging.log_cas_decision("fix", fix.proposal_id, current_state, "fixing", "fixing", "applied", reason)
  local raised = {
    "github-proxy.github_pr_comment_request",
  }
  if label_request ~= nil then
    table.insert(raised, "github-proxy.github_issue_label_request")
  end
  devloop_logging.log_apply("fix", fix.proposal_id, "fixing", next_version, { add = add_labels, remove = remove_labels }, raised)
  devloop_logging.log_raise("fix", fix.proposal_id, "github-proxy.github_pr_comment_request", comment_request)
  if label_request ~= nil then
    devloop_logging.log_raise("fix", fix.proposal_id, "github-proxy.github_issue_label_request", label_request)
  end
  return { kind = "admit", version = next_version }
  end

  if fix.repair_input ~= "ci-failure" then
    return raise_generation(
      devloop_state.next_fix_version(fix.version),
      fix.ci_failure_key,
      fix.gate_failure_excerpt or fix.blocking_gap or reason
    )
  end
  local result, mismatch, current_pr = with_current_classification(
    repo,
    fix.pr_number,
    fix.reviewed_head_sha,
    function(classification)
      local decision = fix_rounds.admit_own_ci_continuation(current_state, classification, {
        dept = "fix",
        from_state = "fixing",
        proposal_id = fix.proposal_id,
        review_proposal_id = fix.review_proposal_id,
        review_dedup_key = fix.review_dedup_key,
        pr_number = fix.pr_number,
        source_ref = fix.source_ref,
        reason = "own-CI-red speculation churn exhausted the fix-round budget",
      })
      if decision.kind == "not-own-ci" then
        raise_reviewing(repo, issue_number, fix, fix.reviewed_head_sha, decision.current_pr.head_sha,
          "own-CI gate no longer requires speculative repair: " .. tostring(decision.reason))
        return { kind = "reviewing" }
      end
      if decision.kind ~= "admit" then
        return decision
      end
      return raise_generation(decision.version, decision.ci_failure_key, decision.reason)
    end,
    {
      dept = "fix",
      proposal_id = fix.proposal_id,
      error_class = "gh-pr-speculative-refix-view-failed",
    }
  )
  if mismatch == "head-mismatch" then
    raise_reviewing(repo, issue_number, fix, fix.reviewed_head_sha, current_pr.head_sha,
      "own-CI gate head changed before speculative repair")
    return { kind = "reviewing" }
  end
  return result
end

return M
end

return C
