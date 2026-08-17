local branch_progress = require("departments.implement.branch_progress")
local devloop_logging = require("devloop.logging")
local result_checkpoint = require("departments.implement.result_checkpoint")

local M = {}

local function adopt_completed_result(attempt_plan, completed)
  if completed == nil then return end
  local ready = attempt_plan.marker_ready
  attempt_plan.checkpoint = nil
  attempt_plan.completed_result = completed
  attempt_plan.attempt = attempt_plan.completed_attempt
  devloop_logging.log_cas_decision("implement", ready.proposal_id, {
    state = "implementing",
    version = ready.dedup_key,
  }, "implementing", "implementing", "resume-completed-result(replacement-boundary)",
    "version-bound implementation result became durable before replacement execution; resuming harvest")
end

local function rehydrate_completed_result(git, attempt_plan)
  if attempt_plan.completed_result ~= nil then return nil end
  local ready = attempt_plan.marker_ready
  local progress = branch_progress.local_branch_fact(
    attempt_plan.base_head,
    attempt_plan.branch,
    attempt_plan.branches.integration,
    ready.dedup_key
  )
  adopt_completed_result(attempt_plan,
    result_checkpoint.rehydrate(git, progress, ready.dedup_key))
  return progress
end

function M.prepare(git, attempt_plan, prepare)
  if attempt_plan.completed_attempt == nil then
    return prepare()
  end
  -- The receipt commit is the cross-runtime fact. Reconcile on both sides of
  -- replacement preparation so a finisher that lands during preparation wins.
  local progress = rehydrate_completed_result(git, attempt_plan)
  local worktree, codex_started_at, exec_ref, receiver_authorization, completed_result = prepare()
  attempt_plan.completed_result = completed_result
  if progress ~= nil and attempt_plan.completed_result == nil then
    adopt_completed_result(attempt_plan,
      result_checkpoint.rehydrate_worktree(git, worktree, progress, attempt_plan.marker_ready.dedup_key))
  end
  return worktree, codex_started_at, exec_ref, receiver_authorization, attempt_plan.completed_result
end

return M
