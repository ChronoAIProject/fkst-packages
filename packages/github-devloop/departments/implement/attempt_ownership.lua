local worktree_lifecycle = require("departments.implement.worktree")

local M = {}

local function promotes_branch(outcome)
  return outcome.kind == "implementing" or outcome.kind == "implement-checkpoint"
end

function M.release(git, worktree)
  worktree_lifecycle.release_attempt(git, worktree)
end

function M.complete(git, worktree, outcome, base_head, handle_outcome)
  if promotes_branch(outcome) then
    local promoted, reason = worktree_lifecycle.promote_attempt_head(
      git, outcome.branch, base_head, outcome.head_sha)
    if not promoted then
      M.release(git, worktree)
      return false, reason
    end
  end

  local handled, handle_error = pcall(handle_outcome)
  local released, release_error = pcall(M.release, git, worktree)
  if not handled then error(handle_error, 0) end
  if not released then error(release_error, 0) end
  return true, "completed"
end

return M
