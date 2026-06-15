local shell = require("std.github.shell")

local M = {}

local function gh_issue_view_cmd(repo, issue_number, fields)
  local selected_fields = tostring(fields or "")
  if selected_fields == "" or selected_fields:match("[^%w_,]") or selected_fields:match("^,") or selected_fields:match(",$") or selected_fields:match(",,") then
    error("github-devloop: invalid issue view fields")
  end
  return "gh issue view " .. shell.shell_single_quote(issue_number)
    .. " --repo " .. shell.shell_single_quote(repo)
    .. " --json " .. selected_fields
end

local function gh_issue_view_loop_cmd(repo, issue_number)
  return gh_issue_view_cmd(repo, issue_number, "title,updatedAt,labels,comments,state")
end

local function assignee_logins(assignees)
  local logins = {}
  for _, assignee in ipairs(assignees or {}) do
    if type(assignee) == "table" and assignee.login ~= nil then
      table.insert(logins, tostring(assignee.login))
    elseif type(assignee) == "string" then
      table.insert(logins, assignee)
    end
  end
  return logins
end

local function issue_author_login(decoded)
  if type(decoded.author) == "table" and decoded.author.login ~= nil then
    return tostring(decoded.author.login)
  end
  if type(decoded.user) == "table" and decoded.user.login ~= nil then
    return tostring(decoded.user.login)
  end
  if decoded.author_login ~= nil then
    return tostring(decoded.author_login)
  end
  return nil
end

local function comments_from_json(comments_json)
  local comments = {}
  for _, comment in ipairs(comments_json or {}) do
    if type(comment) == "table" and comment.body ~= nil then
      local author_login = nil
      if type(comment.author) == "table" and comment.author.login ~= nil then
        author_login = tostring(comment.author.login)
      elseif type(comment.user) == "table" and comment.user.login ~= nil then
        author_login = tostring(comment.user.login)
      elseif comment.author_login ~= nil then
        author_login = tostring(comment.author_login)
      end
      table.insert(comments, {
        id = comment.id,
        body = tostring(comment.body),
        author_login = author_login,
        created_at = comment.createdAt or comment.created_at,
      })
    elseif type(comment) == "string" then
      table.insert(comments, {
        body = comment,
        author_login = "fkst-test-bot",
      })
    end
  end
  return comments
end

local function label_names(labels_json)
  local labels = {}
  for _, label in ipairs(labels_json or {}) do
    if type(label) == "table" and label.name ~= nil then
      table.insert(labels, tostring(label.name))
    elseif type(label) == "string" then
      table.insert(labels, label)
    end
  end
  return labels
end

local function parse_issue_view_result(stdout)
  local decoded = json.decode(stdout or "{}")

  return {
    labels = label_names(decoded.labels),
    comments = comments_from_json(decoded.comments),
    assignees = assignee_logins(decoded.assignees),
    author_login = issue_author_login(decoded),
  }
end

local function parse_issue_view_loop(stdout)
  local decoded = json.decode(stdout or "{}")
  local result = parse_issue_view_result(stdout)
  return {
    title = tostring(decoded.title or ""),
    updated_at = decoded.updatedAt or decoded.updated_at,
    state = decoded.state,
    labels = result.labels,
    comments = result.comments,
    assignees = result.assignees,
    author_login = result.author_login,
  }
end

local function repo_and_number(source_ref)
  assert(type(source_ref) == "table", "read_issue requires a source_ref")
  local repo, kind, number = tostring(source_ref.ref or ""):match("^([^#]+)#([a-z]+)/(%d+)$")
  assert(kind == "issue", "read_issue requires an issue source_ref")
  return repo, tonumber(number)
end

function M.install(handle)
  function handle.read_issue(source_ref)
    local repo, number = repo_and_number(source_ref)
    local out = handle._exec(gh_issue_view_loop_cmd(repo, number), 30, "gh issue view")
    local issue = parse_issue_view_loop(out.stdout)
    issue.number = number
    issue.source_ref = { kind = source_ref.kind, ref = source_ref.ref }
    return issue
  end
end

return M
