local branch_progress = require("departments.implement.branch_progress")
local m_facts = require("devloop.markers.facts")
local pr_child_handoff = require("departments.implement.pr_child_handoff")
local result_checkpoint = require("departments.implement.result_checkpoint")
local worktree_lifecycle = require("departments.implement.worktree")
local devloop_logging = require("devloop.logging")

local M = {}
local MAX_IMPLEMENT_ATTEMPTS = 2

local function checkpoint_matches_progress(checkpoint, progress)
  return checkpoint ~= nil
    and progress ~= nil
    and checkpoint.branch == progress.branch
    and checkpoint.head_sha == progress.head_sha
end

function M.plan(args)
  local marker_ready = args.marker_ready
  local current = args.current
  local fact = m_facts.implementing_fact(
    current.comments, marker_ready.proposal_id, marker_ready.dedup_key)
  local checkpoint = fact == nil and m_facts.implement_checkpoint_fact(
    current.comments, marker_ready.proposal_id, marker_ready.dedup_key) or nil
  local progress = branch_progress.remote_branch_fact(
    args.git,
    fact ~= nil and fact.branch or args.branch,
    fact ~= nil and fact.base_branch or args.branches.integration,
    fact or { proposal_id = marker_ready.proposal_id, dedup_key = marker_ready.dedup_key })
  local completed_result, resume_checkpoint = nil, checkpoint
  if progress ~= nil and fact ~= nil then
    progress.proposal_id, progress.dedup_key = marker_ready.proposal_id, marker_ready.dedup_key
    pr_child_handoff.raise_awaiting_pr_from_fact("implement", args.repo, args.issue_number,
      marker_ready, current, progress, "implementing remote branch progress is visible")
    return nil
  elseif progress ~= nil then
    completed_result = result_checkpoint.rehydrate(args.git, progress, marker_ready.dedup_key)
    resume_checkpoint = completed_result ~= nil and progress
      or (checkpoint_matches_progress(checkpoint, progress) and checkpoint or progress)
    local decision = completed_result ~= nil and "resume-completed-result(remote-progress)"
      or (resume_checkpoint == checkpoint and "skip-wip-checkpoint(remote-progress)"
        or "skip-unmarked-progress(remote-progress)")
    local reason = completed_result ~= nil and "version-bound implementation result is durable; resuming harvest"
      or (resume_checkpoint == checkpoint and "remote branch progress is a WIP checkpoint; retrying implementation attempt"
        or "remote branch progress has no durable implementing fact; retrying implementation attempt")
    devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, args.state,
      "implementing", "implementing", decision, reason)
  end

  local base_head = worktree_lifecycle.prepare_base(args.branches)
  local local_progress = nil
  if resume_checkpoint == nil then
    local_progress = branch_progress.local_branch_fact(
      base_head, args.branch, args.branches.integration, marker_ready.dedup_key)
    if local_progress ~= nil and fact ~= nil then
      local_progress.proposal_id = marker_ready.proposal_id
      pr_child_handoff.raise_awaiting_pr_from_fact("implement", args.repo, args.issue_number,
        marker_ready, current, local_progress, "local implementation branch progress is visible")
      return nil
    elseif local_progress ~= nil then
      completed_result = result_checkpoint.rehydrate(args.git, local_progress, marker_ready.dedup_key)
      local decision = completed_result ~= nil and "resume-completed-result(local-progress)"
        or "skip-unmarked-progress(local-progress)"
      local reason = completed_result ~= nil and "version-bound implementation result is durable; resuming harvest"
        or "local branch progress has no durable implementing fact; retrying implementation attempt"
      devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, args.state,
        "implementing", "implementing", decision, reason)
    end
  end

  local has_progress = progress ~= nil or local_progress ~= nil
  local attempts = args.core.implement_attempt_count(
    current.comments, marker_ready.proposal_id, marker_ready.dedup_key)
  if attempts >= MAX_IMPLEMENT_ATTEMPTS and not has_progress then
    devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, args.state,
      "implementing", "impl-failed", "applied(attempts-exhausted)",
      "implementation attempts exhausted with no PR or branch progress")
    args.raise_impl_failed(
      args.repo, args.issue_number, marker_ready, "retry-exhausted", "UNKNOWN", false,
      "No linked PR, remote branch, or local branch progress was visible after "
        .. tostring(attempts) .. " attempts.", attempts)
    return nil
  end
  devloop_logging.log_cas_decision("implement", marker_ready.proposal_id, args.state,
    "implementing", "implementing",
    has_progress and "applied(retry-progress)" or "applied(retry-no-progress)",
    has_progress and "recoverable branch progress is visible; retrying implementation attempt"
      or "no PR or branch progress is visible; retrying implementation attempt")
  return {
    base_head = base_head,
    attempt = completed_result ~= nil and math.max(attempts, 1) or attempts + 1,
    checkpoint = resume_checkpoint,
    completed_result = completed_result,
  }
end

return M
