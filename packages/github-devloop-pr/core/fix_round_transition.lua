local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local core = require("core")
local requests_labels = require("devloop.requests.labels")
local requests_review = require("devloop.requests.review")
local payloads_builders = require("devloop.payloads.builders")
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local fix_round_authority = require("devloop.fix_round_authority")

local M = {}

M.next_or_decompose = fix_round_authority.next_or_decompose

function M.raise_decompose(transition, opts)
  if transition == nil or transition.kind ~= "decompose" then
    error("github-devloop: fix-round-transition-invalid: invalid fix-round decompose transition")
  end
  local state = opts.current_state or {}
  if tostring(state.version or "") ~= transition.version then
    error("github-devloop: fix-round-transition-version-mismatch: fix-round decompose version mismatch")
  end
  local review = opts.review or {}
  local review_dedup_key = devloop_base.canonical_pr_review_consensus_dedup_for_proposal(
    review.review_dedup_key,
    review.review_proposal_id
  ) or review.review_dedup_key
  local terminal_head_sha = opts.current_head_sha or review.reviewed_head_sha
  local fix_reconcile = conv_reconcile.build_devloop_fix_reconcile_payload({
    proposal_id = review.proposal_id,
    review_proposal_id = review.review_proposal_id,
    review_dedup_key = review_dedup_key,
    reviewed_head_sha = terminal_head_sha,
    pr_number = review.pr_number,
    source_ref = opts.source_ref or review.source_ref,
  }, transition.version)
  devloop_logging.log_cas_decision(
    opts.dept,
    review.proposal_id,
    state,
    opts.from_state,
    "blocked",
    "applied(fix-loop-max-rounds)",
    opts.reason
  )
  devloop_logging.log_raise(opts.dept, review.proposal_id, "devloop_fix_reconcile", fix_reconcile)
end

local function copy_table(value)
  local copy = {}
  for key, field in pairs(value or {}) do
    copy[key] = field
  end
  return copy
end

local function advanced_review_meta_payload(fix, transition)
  local review_dedup_key = devloop_base.canonical_pr_review_consensus_dedup_for_proposal(
    fix.review_dedup_key,
    fix.review_proposal_id
  ) or fix.review_dedup_key
  return payloads_builders.build_devloop_review_meta_payload({
    proposal_id = fix.review_proposal_id,
    dedup_key = review_dedup_key,
    source_ref = fix.source_ref,
  }, fix.proposal_id, transition.version, fix.pr_number, 0, fix.source_ref)
end

function M.raise_review_meta(opts)
  local fix = opts.fix
  local review_meta = nil
  if opts.transition ~= nil then
    if opts.transition.kind ~= "advance" then
      error("github-devloop: fix-round-transition-invalid: invalid fix-round review-meta transition")
    end
    review_meta = advanced_review_meta_payload(fix, opts.transition)
  else
    review_meta = {
      schema = "github-devloop.review-meta.v1",
      proposal_id = fix.proposal_id,
      review_proposal_id = fix.review_proposal_id,
      review_dedup_key = fix.review_dedup_key,
      version = fix.version,
      pr_number = fix.pr_number,
      n = 0,
      dedup_key = fix.dedup_key,
      source_ref = fix.source_ref,
    }
  end
  local transition_fix = copy_table(fix)
  transition_fix.version = review_meta.version
  transition_fix.review_dedup_key = review_meta.review_dedup_key
  transition_fix.dedup_key = review_meta.dedup_key
  local comment_request = core.build_fix_review_meta_comment_request(
    opts.repo,
    opts.issue_number,
    transition_fix,
    opts.reason,
    opts.detail
  )
  local label_request = core.build_fix_review_meta_label_request(
    opts.repo,
    opts.issue_number,
    transition_fix,
    opts.reason
  )
  local add_labels, remove_labels = devloop_state.state_label_changes("review-meta")
  devloop_logging.log_apply("fix", fix.proposal_id, "review-meta", transition_fix.version, {
    add = add_labels,
    remove = remove_labels,
  }, {
    "github-proxy.github_pr_comment_request",
    "github-proxy.github_issue_label_request",
    "devloop_review_meta",
  })
  devloop_logging.log_raise("fix", fix.proposal_id, "github-proxy.github_pr_comment_request", comment_request)
  if opts.issue_number ~= nil then
    devloop_logging.log_raise("fix", fix.proposal_id, "github-proxy.github_issue_label_request", label_request)
  end
  devloop_logging.log_raise("fix", fix.proposal_id, "devloop_review_meta", review_meta)
end

local function bounded_fix_summary(value)
  local text = tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #text > 600 then
    text = text:sub(1, 600)
  end
  return text
end

function M.raise_reviewing(repo, issue_number, fix, old_head_sha, new_head_sha, reason, summary)
  local transition = M.next_or_decompose(fix.version)
  if transition.kind == "decompose" then
    M.raise_decompose(transition, {
      dept = "fix",
      current_state = { state = "fixing", version = fix.version },
      from_state = "fixing",
      reason = reason,
      review = fix,
      current_head_sha = new_head_sha,
    })
    return
  end
  requests_review.raise_fix_reviewing(core, {
    dept = "fix",
    repo = repo,
    issue_number = issue_number,
    fix = fix,
    old_head_sha = old_head_sha,
    new_head_sha = new_head_sha,
    new_version = transition.version,
    reason = reason,
    fix_summary = bounded_fix_summary(summary),
    clear_fix_summary = true,
  })
end

function M.raise_stale_speculation_refix(repo, issue_number, fix, current_state, current_predecessor_set, reason)
  local transition = M.next_or_decompose(current_state.version)
  if transition.kind == "decompose" then
    M.raise_decompose(transition, {
      dept = "fix",
      current_state = current_state,
      from_state = "fixing",
      reason = reason,
      review = fix,
    })
    return
  end
  local next_version = transition.version
  local merge_ready = {
    proposal_id = fix.proposal_id,
    pr_number = fix.pr_number,
    version = devloop_state._strip_latest_fix_version_suffix(fix.version),
    review_proposal_id = fix.review_proposal_id,
    review_dedup_key = fix.review_dedup_key,
    reviewed_head_sha = fix.reviewed_head_sha,
    dedup_key = fix.dedup_key,
  }
  local comment_request = requests_review.build_merge_gate_fix_comment_request(core,
    repo,
    issue_number,
    merge_ready,
    next_version,
    fix.gate_failure_excerpt or fix.blocking_gap or reason,
    fix.gate_baseline_sha,
    fix.source_ref,
    current_predecessor_set,
    {
      blocking_gap = fix.blocking_gap,
      gate_failure_excerpt = fix.gate_failure_excerpt,
      preserve_nil_gate_failure_excerpt = true,
      repair_input = fix.repair_input,
      ci_failure_key = fix.ci_failure_key,
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
end

return M
