local forge_validators = require("devloop.forge_validators")
local github_factory = require("devloop.github_factory")

local D = {}

local issue_selection = "number state stateReason repository{nameWithOwner} duplicateOf{number state stateReason repository{nameWithOwner}} blockedBy(first:50){totalCount pageInfo{hasNextPage} nodes{number state stateReason repository{nameWithOwner} duplicateOf{number state stateReason repository{nameWithOwner}}}}"

D.queries = {
  dependency_blocked_by = '{repository(owner:"{{owner}}",name:"{{name}}"){issue(number:{{issue_number}}){'
    .. issue_selection
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
  return tostring(template):gsub("{{([%w_]+)}}", function(field_name)
    local value = fields and fields[field_name]
    if value == nil then
      error("github-devloop: graphql-template-missing-field: " .. tostring(field_name))
    end
    return tostring(value)
  end)
end

function D.render_query(name, fields)
  local template = D.queries[name]
  if template == nil then
    error("github-devloop: graphql-template-unknown-query: " .. tostring(name))
  end
  return render_query(template, fields)
end

function D.render_batch_query(name, fields, issue_numbers)
  if name ~= "dependency_blocked_by" then
    error("github-devloop: graphql-template-unknown-batch-query: " .. tostring(name))
  end
  if type(issue_numbers) ~= "table" or #issue_numbers == 0 then
    error("github-devloop: graphql-batch-empty: dependency_blocked_by")
  end

  local selections = {}
  local seen = {}
  for _, issue_number in ipairs(issue_numbers) do
    local number = tonumber(issue_number)
    if not forge_validators.is_positive_pr_number(number) then
      error("github-devloop: graphql-batch-invalid-issue-number: invalid issue number")
    end
    number = math.floor(number)
    if seen[number] then
      error("github-devloop: graphql-batch-duplicate-issue-number: " .. tostring(number))
    end
    seen[number] = true
    table.insert(selections, "issue_" .. tostring(number) .. ":issue(number:" .. tostring(number) .. "){"
      .. issue_selection
      .. "}")
  end

  return render_query('{repository(owner:"{{owner}}",name:"{{name}}"){'
    .. table.concat(selections, " ")
    .. "}}", fields)
end

local function execute(query, timeout, exec)
  local run = exec or exec_argv
  if type(run) ~= "function" then
    error("github-devloop: adapter-unavailable: GitHub GraphQL adapter requires exec_argv")
  end
  return github_result(function()
    return github_factory.new(run, exec_sync).graphql(query, nil, timeout or 30)
  end)
end

function D.execute(name, fields, timeout, exec)
  return execute(D.render_query(name, fields), timeout, exec)
end

function D.execute_batch(name, fields, issue_numbers, timeout, exec)
  return execute(D.render_batch_query(name, fields, issue_numbers), timeout, exec)
end

local function parse_dependency_issue(node, include_duplicate)
  if type(node) ~= "table" or not forge_validators.is_positive_pr_number(node.number) then
    return nil
  end
  local issue_repo = node.repository and node.repository.nameWithOwner
  if type(issue_repo) ~= "string" or issue_repo == "" then
    return nil
  end
  local issue = {
    number = tonumber(node.number),
    state = tostring(node.state or ""),
    state_reason = tostring(node.stateReason or node.state_reason or ""),
    repo = issue_repo,
    duplicate_projection_complete = include_duplicate == true,
  }
  local duplicate_of = node.duplicateOf or node.duplicate_of
  if include_duplicate and type(duplicate_of) == "table" then
    issue.duplicate_of = parse_dependency_issue(duplicate_of, false)
    if issue.duplicate_of == nil then
      return nil
    end
  elseif include_duplicate and duplicate_of ~= nil and type(duplicate_of) ~= "userdata" then
    return nil
  end
  return issue
end

local function parse_issue(issue)
  if issue == nil then
    return nil, nil, nil, "missing-issue"
  end
  if type(issue) ~= "table" then
    return nil
  end
  local blocked_by = issue.blockedBy
  local nodes = blocked_by and blocked_by.nodes
  if type(nodes) ~= "table" then
    return nil
  end

  local blockers = {}
  for _, node in ipairs(nodes) do
    local blocker = parse_dependency_issue(node, true)
    if blocker == nil then
      return nil
    end
    table.insert(blockers, blocker)
  end

  local issue_projection = nil
  if issue.number ~= nil then
    issue_projection = parse_dependency_issue(issue, true)
    if issue_projection == nil then
      return nil
    end
  end

  local total = blocked_by.totalCount
  local page = blocked_by.pageInfo
  local truncated = (type(total) == "number" and total > #blockers)
    or (type(page) == "table" and page.hasNextPage == true)
  return blockers, truncated, issue_projection, nil
end

function D.parse(stdout)
  local ok, decoded = pcall(json.decode, stdout or "")
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local issue = decoded.data
    and decoded.data.repository
    and decoded.data.repository.issue
  return parse_issue(issue)
end

function D.parse_batch(stdout, issue_numbers)
  local ok, decoded = pcall(json.decode, stdout or "")
  local repository = ok
    and type(decoded) == "table"
    and decoded.data
    and decoded.data.repository
  if type(repository) ~= "table" then
    return nil
  end

  local entries = {}
  for _, issue_number in ipairs(issue_numbers or {}) do
    local blockers, truncated, issue, parse_reason = parse_issue(repository["issue_" .. tostring(issue_number)])
    local entry = { blockers = blockers, issue = issue }
    if blockers == nil then
      entry.reason = parse_reason or "malformed-json"
    elseif truncated then
      entry.blockers = nil
      entry.reason = "blockedby-truncated"
    end
    entries[tonumber(issue_number)] = entry
  end
  return entries
end

return D
