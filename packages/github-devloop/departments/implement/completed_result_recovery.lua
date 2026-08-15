local M = {}

function M.run(with_lock_fn, lock_key, prepare, resume)
  local prepared = nil
  local recovered = false
  with_lock_fn(lock_key, function()
    local worktree, started_at, exec_ref, authorization, completed_result = prepare()
    if worktree ~= nil then
      prepared = {
        worktree = worktree,
        started_at = started_at,
        exec_ref = exec_ref,
        authorization = authorization,
        completed_result = completed_result,
      }
    end
    if prepared ~= nil and prepared.completed_result ~= nil then
      recovered = true
      resume(prepared)
    end
  end)
  return prepared, recovered
end

return M
