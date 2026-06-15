local M = {}

function M.model(seed)
  return {
    issues = seed and seed.issues or {},
    writes = seed and seed.writes or {},
  }
end

function M.new(model)
  assert(type(model) == "table", "std.github_fake.new requires a model")
  local handle = {}
  function handle.read_issue(source_ref)
    local issue = model.issues[source_ref.ref]
    if issue == nil then
      error("fake: unknown issue " .. tostring(source_ref.ref))
    end
    return issue
  end
  return handle
end

return M
