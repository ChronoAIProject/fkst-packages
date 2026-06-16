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
    writes = seed and seed.writes or {},
  }
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
  function handle.list_issue_comments(repo, issue_number)
    table.insert(model.writes, {
      kind = "list_issue_comments",
      repo = tostring(repo),
      issue_number = tostring(issue_number),
    })
    local key = tostring(repo) .. "#issue/" .. tostring(issue_number)
    local fixture = model.issues[key]
    if type(fixture) == "table" and type(fixture.comments) == "table" then
      return copy(issue.normalize_issue(fixture, { kind = "external", ref = key }).comments)
    end
    return {}
  end
  function handle.create_issue_comment(repo, issue_number, body_file)
    local comment = {
      id = tostring(#model.writes + 1),
      body = "",
      author_login = "fake",
    }
    table.insert(model.writes, {
      kind = "create_issue_comment",
      repo = tostring(repo),
      issue_number = tostring(issue_number),
      body_file = tostring(body_file),
      comment = copy(comment),
    })
    return copy(comment)
  end
  function handle.edit_issue_comment(repo, comment_id, body_file)
    local comment = {
      id = tostring(comment_id),
      body = "",
      author_login = "fake",
    }
    table.insert(model.writes, {
      kind = "edit_issue_comment",
      repo = tostring(repo),
      comment_id = tostring(comment_id),
      body_file = tostring(body_file),
      comment = copy(comment),
    })
    return copy(comment)
  end
  return handle
end

return M
