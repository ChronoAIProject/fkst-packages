local M = {}

local function is_git_push_text(command)
  local first = true
  for token in tostring(command or ""):gmatch("%S+") do
    if first then
      if token ~= "git" then
        return false
      end
      first = false
    elseif token == "push" then
      return true
    end
  end
  return false
end

local function skip_option(argv, index)
  local option = argv[index]
  if option == "-C" or option == "-c" or option == "--git-dir" or option == "--work-tree" then
    return index + 2
  end
  return index + 1
end

local function command_index(argv)
  local index = 2
  while index <= #argv and tostring(argv[index]):sub(1, 1) == "-" do
    index = skip_option(argv, index)
  end
  return index
end

function M.is_write_call(call)
  if type(call) == "string" then
    return is_git_push_text(call)
  end
  if type(call) ~= "table" or type(call.argv) ~= "table" or call.argv[1] ~= "git" then
    return false
  end
  return call.argv[command_index(call.argv)] == "push"
end

return M
