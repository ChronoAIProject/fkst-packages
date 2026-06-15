local M = {}

function M.model(seed)
  return {
    refs = seed and seed.refs or {},
    writes = seed and seed.writes or {},
  }
end

function M.new(model)
  assert(type(model) == "table", "std.git_fake.new requires a model")
  local handle = {}
  function handle.show_ref(branch)
    return model.refs[branch]
  end
  return handle
end

return M
