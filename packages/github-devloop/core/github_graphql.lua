local S = {}
local github_factory = require("devloop.github_factory")

local dependency_blocked_by_selection = "blockedBy(first:50){totalCount pageInfo{hasNextPage} nodes{number state stateReason repository{nameWithOwner}}}"

local queries = {
  dependency_blocked_by = '{repository(owner:"{{owner}}",name:"{{name}}"){issue(number:{{issue_number}}){'
    .. dependency_blocked_by_selection
    .. "}}}",
}

local function github_result(fn)
  local ok, result_or_error = pcall(fn)
  if ok then
    return result_or_error
  end
  if type(result_or_error) == "table" and result_or_error.result ~= nil then
    return result_or_error.result
  end
  error(result_or_error)
end

local function render_query(template, fields)
  return tostring(template or ""):gsub("{{([%w_]+)}}", function(name)
    local value = fields and fields[name]
    if value == nil then
      error("github-devloop: graphql-template-missing-field: " .. tostring(name))
    end
    return tostring(value)
  end)
end

local function render_dependency_blocked_by_batch(fields, issue_numbers)
  if type(issue_numbers) ~= "table" or #issue_numbers == 0 then
    error("github-devloop: graphql-batch-empty: dependency_blocked_by")
  end

  local selections = {}
  local seen = {}
  for _, issue_number in ipairs(issue_numbers) do
    local number = tonumber(issue_number)
    if number == nil or number < 1 or number ~= math.floor(number) or number > 2147483647 then
      error("github-devloop: graphql-batch-invalid-issue-number: invalid issue number")
    end
    if seen[number] then
      error("github-devloop: graphql-batch-duplicate-issue-number: " .. tostring(number))
    end
    seen[number] = true
    table.insert(selections, "issue_" .. tostring(number) .. ":issue(number:" .. tostring(number) .. "){"
      .. dependency_blocked_by_selection
      .. "}")
  end

  return render_query('{repository(owner:"{{owner}}",name:"{{name}}"){'
    .. table.concat(selections, " ")
    .. "}}", fields)
end

local function execute_graphql(query, timeout, exec)
  local run = exec or exec_argv
  if type(run) ~= "function" then
    error("github-devloop: adapter-unavailable: GitHub GraphQL adapter requires exec_argv")
  end
  return github_result(function()
    return github_factory.new(run, exec_sync).graphql(query, nil, timeout or 30)
  end)
end

function S.install(M)
  M.github_graphql_queries = queries

  function M.render_github_graphql_query(name, fields)
    local template = queries[name]
    if template == nil then
      error("github-devloop: graphql-template-unknown-query: " .. tostring(name))
    end
    return render_query(template, fields)
  end

  function M.render_github_graphql_batch_query(name, fields, issue_numbers)
    if name ~= "dependency_blocked_by" then
      error("github-devloop: graphql-template-unknown-batch-query: " .. tostring(name))
    end
    return render_dependency_blocked_by_batch(fields, issue_numbers)
  end

  function M.github_graphql(name, fields, timeout, exec)
    local query = M.render_github_graphql_query(name, fields)
    return execute_graphql(query, timeout, exec)
  end

  function M.github_graphql_batch(name, fields, issue_numbers, timeout, exec)
    local query = M.render_github_graphql_batch_query(name, fields, issue_numbers)
    return execute_graphql(query, timeout, exec)
  end
end

return S
