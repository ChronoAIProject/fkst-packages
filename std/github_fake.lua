local M = {}
local issue = require("std.github.issue")

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
    issues = seed and seed.issues or {},
    issue_lists = seed and seed.issue_lists or {},
    pr_lists = seed and seed.pr_lists or {},
    rest_issues = seed and seed.rest_issues or {},
    rest_prs = seed and seed.rest_prs or {},
    comments = seed and seed.comments or {},
    updated_at = seed and seed.updated_at or {},
    graphql = seed and seed.graphql or {},
    issue_create_searches = seed and seed.issue_create_searches or {},
    writes = seed and seed.writes or {},
  }
end

local function result(stdout)
  return { stdout = stdout or "", stderr = "", exit_code = 0 }
end

local function json_string(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\b", "\\b")
  text = text:gsub("\f", "\\f")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  text = text:gsub("[%z\1-\31]", function(char)
    return string.format("\\u%04X", string.byte(char))
  end)
  return '"' .. text .. '"'
end

local function json_array_or_object(value)
  local is_array = true
  local max_index = 0
  for key, _field in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      is_array = false
      break
    end
    if key > max_index then
      max_index = key
    end
  end
  local parts = {}
  if is_array then
    for index = 1, max_index do
      table.insert(parts, M.json(value[index]))
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for key, field in pairs(value) do
    table.insert(parts, json_string(key) .. ":" .. M.json(field))
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.json(value)
  if value == nil then
    return "null"
  end
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  if type(value) == "number" then
    return tostring(value)
  end
  if type(value) == "table" then
    return json_array_or_object(value)
  end
  return json_string(value)
end

function M.new(model)
  assert(type(model) == "table", "std.github_fake.new requires a model")
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
  function handle.read_issue(source_ref)
    local fixture = model.issues[source_ref.ref]
    if fixture == nil then
      error("fake: unknown issue " .. tostring(source_ref.ref))
    end
    return copy(issue.normalize_issue(fixture, source_ref))
  end
  function handle.rest_issue_view(repo, issue_number)
    local key = tostring(repo) .. "#issue/" .. tostring(issue_number)
    local fixture = model.rest_issues[key] or model.issues[key]
    if fixture == nil then
      error("fake: unknown REST issue " .. key)
    end
    return result(type(fixture) == "string" and fixture or M.json(fixture))
  end
  function handle.rest_pr_view(repo, pr_number)
    local key = tostring(repo) .. "#pr/" .. tostring(pr_number)
    local fixture = model.rest_prs[key]
    if fixture == nil then
      error("fake: unknown REST PR " .. key)
    end
    return result(type(fixture) == "string" and fixture or M.json(fixture))
  end
  function handle.issue_comments(repo, issue_number)
    local key = tostring(repo) .. "#issue/" .. tostring(issue_number)
    local fixture = model.comments[key] or {}
    return result(type(fixture) == "string" and fixture or M.json(fixture))
  end
  function handle.entity_updated_at(repo, kind, number)
    local key = tostring(repo) .. "#" .. tostring(kind) .. "/" .. tostring(number)
    return result(model.updated_at[key] or "")
  end
  function handle.issue_create_search(repo, marker)
    local key = tostring(repo) .. "#" .. tostring(marker)
    local fixture = model.issue_create_searches[key] or {}
    return result(type(fixture) == "string" and fixture or M.json(fixture))
  end
  function handle.graphql_query(query)
    local fixture = model.graphql[tostring(query)] or '{"data":{}}'
    return result(type(fixture) == "string" and fixture or M.json(fixture))
  end
  function handle.graphql_mutation(query, fields)
    table.insert(model.writes, {
      kind = "graphql_mutation",
      query = tostring(query),
      fields = copy(fields),
    })
    local fixture = model.graphql[tostring(query)] or '{"data":{}}'
    return result(type(fixture) == "string" and fixture or M.json(fixture))
  end
  function handle.issue_list_open(repo)
    local fixture = model.issue_lists[tostring(repo)] or {}
    return result(type(fixture) == "string" and fixture or M.json(fixture))
  end
  function handle.pr_list_open(repo)
    local fixture = model.pr_lists[tostring(repo)] or {}
    return result(type(fixture) == "string" and fixture or M.json(fixture))
  end
  function handle.issue_assign(repo, issue_number, login)
    table.insert(model.writes, {
      kind = "issue_assign",
      repo = tostring(repo),
      issue_number = tostring(issue_number),
      login = tostring(login),
    })
    return result("")
  end
  function handle.issue_unassign(repo, issue_number, login)
    table.insert(model.writes, {
      kind = "issue_unassign",
      repo = tostring(repo),
      issue_number = tostring(issue_number),
      login = tostring(login),
    })
    return result("")
  end
  function handle.issue_create(repo, title, body_file, labels, assignees)
    table.insert(model.writes, {
      kind = "issue_create",
      repo = tostring(repo),
      title = tostring(title),
      body_file = tostring(body_file),
      labels = copy(labels),
      assignees = copy(assignees),
    })
    return result("")
  end
  return handle
end

return M
