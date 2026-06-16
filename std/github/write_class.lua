local M = {}

local write_prefixes = {
  "gh issue comment",
  "gh issue edit",
  "gh issue close",
  "gh issue create",
  "gh issue reopen",
  "gh pr merge",
  "gh pr comment",
  "gh pr edit",
  "gh pr create",
  "gh pr close",
  "gh pr ready",
  "gh pr reopen",
  "gh label add",
  "gh label remove",
  "gh label create",
  "gh workflow run",
}

local write_fragments = {
  "gh api --method POST",
  "gh api --method PATCH",
  "gh api --method PUT",
  "gh api --method DELETE",
  "--add-label",
  "--remove-label",
}

local api_write_methods = {
  POST = true,
  PATCH = true,
  PUT = true,
  DELETE = true,
}

local function starts_with(value, prefix)
  return value:sub(1, #prefix) == prefix
end

local function is_graphql_mutation(command)
  return command:find("gh api graphql", 1, true) ~= nil
    and command:find("mutation") ~= nil
end

local function is_write_text(command_string)
  local command = tostring(command_string or "")
  for _, prefix in ipairs(write_prefixes) do
    if starts_with(command, prefix) then
      return true
    end
  end
  for _, fragment in ipairs(write_fragments) do
    if command:find(fragment, 1, true) ~= nil then
      return true
    end
  end
  return is_graphql_mutation(command)
end

local function skip_option(argv, index)
  local option = argv[index]
  if option == "--repo" or option == "-R" or option == "--hostname" then
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

local function method_from_api_argv(argv, start_index)
  local index = start_index + 1
  while index <= #argv do
    local value = tostring(argv[index] or "")
    if value == "--method" or value == "-X" then
      return tostring(argv[index + 1] or ""):upper()
    end
    local inline = value:match("^%-%-method=(.+)$")
    if inline ~= nil then
      return tostring(inline):upper()
    end
    index = index + 1
  end
  return "GET"
end

local function has_graphql_endpoint(argv, start_index)
  for index = start_index + 1, #argv do
    if argv[index] == "graphql" then
      return true
    end
  end
  return false
end

function M.is_write_call(call)
  if type(call) == "string" then
    return is_write_text(call)
  end
  if type(call) ~= "table" or type(call.argv) ~= "table" or call.argv[1] ~= "gh" then
    return false
  end
  local argv = call.argv
  local index = command_index(argv)
  local command = argv[index]
  local subcommand = argv[index + 1]
  if command == "api" then
    if api_write_methods[method_from_api_argv(argv, index)] then
      return true
    end
    return has_graphql_endpoint(argv, index) and tostring(call.stdin or ""):find("mutation", 1, true) ~= nil
  end
  if command == "issue" then
    return subcommand == "comment"
      or subcommand == "edit"
      or subcommand == "close"
      or subcommand == "create"
      or subcommand == "reopen"
  end
  if command == "pr" then
    return subcommand == "merge"
      or subcommand == "comment"
      or subcommand == "edit"
      or subcommand == "create"
      or subcommand == "close"
      or subcommand == "ready"
      or subcommand == "reopen"
  end
  if command == "label" then
    return subcommand == "add" or subcommand == "remove" or subcommand == "create"
  end
  if command == "workflow" then
    return subcommand == "run"
  end
  return false
end

return M
