local C = {}

local function merge(target, source)
  if source == nil then
    return
  end
  if type(source) ~= "table" then
    error("github-devloop: invalid restart replayer registry")
  end
  for state_name, replay in pairs(source) do
    if type(state_name) ~= "string" or state_name == "" or type(replay) ~= "function" then
      error("github-devloop: invalid restart replayer registration")
    end
    target[state_name] = replay
  end
end

function C.assemble(base, tools, pr_defaults, library_registry, review_registry)
  merge(base, library_registry)
  if review_registry == nil then
    return base
  end
  merge(base, pr_defaults)
  local review_replayers = review_registry
  if type(review_replayers) == "function" then
    review_replayers = review_replayers(tools)
  end
  merge(base, review_replayers)
  return base
end

return C
