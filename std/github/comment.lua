local M = {}

local function comment_id(comment)
  if type(comment) ~= "table" then
    return nil
  end
  local id = comment.databaseId or comment.database_id or comment.id
  if id == nil or tostring(id) == "" then
    return nil
  end
  return tostring(id)
end

local function comment_body(comment)
  if type(comment) == "table" then
    return tostring(comment.body or "")
  end
  return tostring(comment or "")
end

local function author_login(comment)
  if type(comment) ~= "table" then
    return nil
  end
  if type(comment.author) == "table" and comment.author.login ~= nil then
    return tostring(comment.author.login)
  end
  if type(comment.user) == "table" and comment.user.login ~= nil then
    return tostring(comment.user.login)
  end
  if comment.author_login ~= nil then
    return tostring(comment.author_login)
  end
  return nil
end

local function append_comments(comments, value)
  if type(value) ~= "table" then
    return
  end
  if value.id ~= nil or value.body ~= nil or value.user ~= nil or value.author ~= nil then
    local id = comment_id(value)
    if id ~= nil then
      table.insert(comments, {
        id = id,
        body = comment_body(value),
        author_login = author_login(value),
      })
    end
    return
  end
  for _, item in ipairs(value) do
    append_comments(comments, item)
  end
end

local function parse_comments(stdout)
  local ok, decoded = pcall(json.decode, stdout or "[]")
  if not ok then
    return {}
  end
  local comments = {}
  append_comments(comments, decoded)
  return comments
end

local function parse_written_comment(stdout)
  local ok, decoded = pcall(json.decode, stdout or "{}")
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local id = comment_id(decoded)
  if id == nil then
    return nil
  end
  return {
    id = id,
    body = comment_body(decoded),
    author_login = author_login(decoded),
  }
end

local function issue_comments_argv(repo, issue_number)
  return {
    "gh",
    "api",
    "--paginate",
    "--slurp",
    "repos/" .. tostring(repo) .. "/issues/" .. tostring(issue_number) .. "/comments?per_page=100",
  }
end

local function create_issue_comment_argv(repo, issue_number, body_file)
  return {
    "gh",
    "api",
    "--method",
    "POST",
    "repos/" .. tostring(repo) .. "/issues/" .. tostring(issue_number) .. "/comments",
    "--field",
    "body=@" .. tostring(body_file),
  }
end

local function edit_issue_comment_argv(repo, comment_id_value, body_file)
  if comment_id_value == nil or tostring(comment_id_value) == "" then
    error("std.github: invalid comment id")
  end
  return {
    "gh",
    "api",
    "--method",
    "PATCH",
    "repos/" .. tostring(repo) .. "/issues/comments/" .. tostring(comment_id_value),
    "--field",
    "body=@" .. tostring(body_file),
  }
end

function M.normalize_comments(stdout)
  return parse_comments(stdout)
end

function M.normalize_written_comment(stdout)
  return parse_written_comment(stdout)
end

function M.install(handle)
  function handle.list_issue_comments(repo, issue_number, opts)
    local options = opts or {}
    local out = handle._exec(
      issue_comments_argv(repo, issue_number),
      tonumber(options.timeout) or 30,
      options.context or "gh issue comments"
    )
    return parse_comments(out.stdout)
  end

  function handle.create_issue_comment(repo, issue_number, body_file, opts)
    local options = opts or {}
    local out = handle._exec(
      create_issue_comment_argv(repo, issue_number, body_file),
      tonumber(options.timeout) or 30,
      options.context or "gh issue comment"
    )
    return parse_written_comment(out.stdout)
  end

  function handle.edit_issue_comment(repo, comment_id_value, body_file, opts)
    local options = opts or {}
    local out = handle._exec(
      edit_issue_comment_argv(repo, comment_id_value, body_file),
      tonumber(options.timeout) or 30,
      options.context or "gh comment edit"
    )
    return parse_written_comment(out.stdout)
  end
end

return M
