local M = {}
local git = require("forge.git")

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, field in pairs(value) do
    result[copy(key)] = copy(field)
  end
  return result
end

function M.model(seed)
  return {
    refs = seed and seed.refs or {},
    writes = seed and seed.writes or {},
  }
end

function M.new(model)
  assert(type(model) == "table", "forge.git_fake.new requires a model")
  local handle = { _model = model }
  function handle._exec(argv, timeout, context)
    table.insert(model.writes, {
      kind = "exec",
      argv = copy(argv),
      timeout = timeout,
      context = context,
    })
    return { stdout = "", stderr = "", exit_code = 0 }
  end
  require("forge.git.refs").install(handle)
  function handle.git_worktree_remove_if_present(worktree, timeout)
    local dir_result = git.run_path_is_directory(worktree, 30)
    if dir_result.exit_code == 1 then
      return { stdout = "", stderr = "", exit_code = 0 }
    end
    if dir_result.exit_code ~= 0 then
      return dir_result
    end
    return handle.worktree_remove(worktree, timeout)
  end
  return handle
end

return M
