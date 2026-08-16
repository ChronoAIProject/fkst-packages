local branch_progress = require("departments.implement.branch_progress")
local devloop_logging = require("devloop.logging")
local result_checkpoint = require("departments.implement.result_checkpoint")

local M = {}

local function rehydrate_completed_result(git, attempt_plan)
  if attempt_plan.completed_result ~= nil then return end
  local ready = attempt_plan.marker_ready
  local progress = branch_progress.local_branch_fact(
    attempt_plan.base_head,
    attempt_plan.branch,
    attempt_plan.branches.integration,
    ready.dedup_key
  )
  local completed = result_checkpoint.rehydrate(git, progress, ready.dedup_key)
  if completed == nil then return end

  attempt_plan.checkpoint = nil
  attempt_plan.completed_result = completed
  attempt_plan.attempt = attempt_plan.completed_attempt
  devloop_logging.log_cas_decision("implement", ready.proposal_id, {
    state = "implementing",
    version = ready.dedup_key,
  }, "implementing", "implementing", "resume-completed-result(replacement-boundary)",
    "version-bound implementation result became durable before replacement start; resuming harvest")
end

function M.prepare(with_lock_fn, git, attempt_plan, prepare)
  if attempt_plan.completed_attempt == nil then
    return prepare()
  end
  local ready = attempt_plan.marker_ready
  return result_checkpoint.with_version_lock(with_lock_fn, ready.proposal_id, ready.dedup_key, function()
    rehydrate_completed_result(git, attempt_plan)
    return prepare()
  end)
end

return M
