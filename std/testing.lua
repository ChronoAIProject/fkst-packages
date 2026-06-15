local M = {}

local function capture_raises(fn)
  local old_raise = raise
  local raised = {}
  raise = function(queue, payload)
    table.insert(raised, {
      queue = queue,
      payload = payload,
    })
  end
  local ok, result = pcall(fn)
  raise = old_raise
  if not ok then
    error(result)
  end
  return result, raised
end

function M.run_fake(dept, event)
  assert(type(dept) == "table", "dept must be a table")
  assert(type(dept.pipeline) == "function", "dept must expose .pipeline")
  local result, raises = capture_raises(function()
    return dept.pipeline(event)
  end)
  return result, { raises = raises }
end

return M
