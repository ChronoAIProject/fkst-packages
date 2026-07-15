local M = {}

local function copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local copied = {}
  for key, child in pairs(value) do
    copied[key] = copy_value(child)
  end
  return copied
end

function M.model(options)
  local config = options or {}
  return {
    calls = {},
    navigation = copy_value(config.navigation or {
      blank_render = false,
      console_error_count = 0,
      network_error_count = 0,
      screenshot_ref = {
        kind = "host-worktree",
        ref = ".fkst/artifacts/browser-qa/fake.png",
      },
    }),
    navigation_error = copy_value(config.navigation_error),
  }
end

function M.new(model)
  local state = model or M.model()
  local handle = {}

  function handle.navigate(url, viewport)
    table.insert(state.calls, {
      url = url,
      viewport = copy_value(viewport),
    })
    if state.navigation_error ~= nil then
      return nil, copy_value(state.navigation_error)
    end
    return copy_value(state.navigation), nil
  end

  handle._model = state
  return handle
end

return M
