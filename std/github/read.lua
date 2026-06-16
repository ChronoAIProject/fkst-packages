local M = {}

local issue_create_search_fields = "number,title,state,author,body,url"
local max_label_len = 80
local max_login_len = 80

local function timeout_from(opts)
  return tonumber(opts and opts.timeout) or 30
end

local function rest_path(repo, kind, number)
  return "repos/" .. tostring(repo) .. "/" .. tostring(kind) .. "/" .. tostring(number)
end

local function comments_path(repo, issue_number)
  return rest_path(repo, "issues", issue_number) .. "/comments?per_page=100"
end

local function open_list_path(repo, kind)
  return "repos/" .. tostring(repo) .. "/" .. tostring(kind) .. "?state=open&per_page=100"
end

local function entity_kind_path(kind)
  if kind == "pr" then
    return "pulls"
  end
  if kind == "issue" then
    return "issues"
  end
  error("std.github: invalid entity kind")
end

local function issue_edit_assignee_argv(repo, issue_number, flag, login)
  return {
    "gh",
    "issue",
    "edit",
    tostring(issue_number),
    "--repo",
    tostring(repo),
    flag,
    tostring(login),
  }
end

local function is_bounded_string(value, limit)
  return type(value) == "string" and value ~= "" and #value <= limit
end

local function is_valid_login(value)
  return is_bounded_string(value, max_login_len)
    and tostring(value):find("^[%w%-%[%]_.]+$") ~= nil
end

local function append_labels(argv, labels)
  if type(labels) ~= "table" then
    return
  end
  for _, label in ipairs(labels) do
    if is_bounded_string(label, max_label_len) then
      table.insert(argv, "--label")
      table.insert(argv, tostring(label))
    end
  end
end

local function append_assignees(argv, assignees)
  if type(assignees) ~= "table" then
    return
  end
  for _, login in ipairs(assignees) do
    if is_valid_login(login) then
      table.insert(argv, "--assignee")
      table.insert(argv, tostring(login))
    end
  end
end

local function append_fields(argv, fields)
  if type(fields) ~= "table" then
    return
  end
  for _, pair in ipairs(fields) do
    if type(pair) == "table" and pair[1] ~= nil then
      table.insert(argv, "-f")
      table.insert(argv, tostring(pair[1]) .. "=" .. tostring(pair[2] or ""))
    end
  end
end

function M.install(handle)
  function handle.rest_issue_view(repo, issue_number, opts)
    return handle._exec({ "gh", "api", rest_path(repo, "issues", issue_number) }, timeout_from(opts), "gh issue REST view")
  end

  function handle.rest_pr_view(repo, pr_number, opts)
    return handle._exec({ "gh", "api", rest_path(repo, "pulls", pr_number) }, timeout_from(opts), "gh PR REST view")
  end

  function handle.issue_comments(repo, issue_number, opts)
    return handle._exec({
      "gh",
      "api",
      "--paginate",
      "--slurp",
      comments_path(repo, issue_number),
    }, timeout_from(opts), "gh issue comments")
  end

  function handle.entity_updated_at(repo, kind, number, opts)
    return handle._exec({
      "gh",
      "api",
      rest_path(repo, entity_kind_path(tostring(kind or "")), number),
      "--jq",
      ".updated_at // .updatedAt // \"\"",
    }, timeout_from(opts), "gh entity updated_at")
  end

  function handle.issue_create_search(repo, marker, opts)
    return handle._exec({
      "gh",
      "issue",
      "list",
      "--repo",
      tostring(repo),
      "--state",
      "all",
      "--limit",
      "100",
      "--search",
      tostring(marker),
      "--json",
      issue_create_search_fields,
    }, timeout_from(opts), "gh issue list")
  end

  function handle.graphql_query(query, opts)
    return handle._exec({
      "gh",
      "api",
      "graphql",
      "-f",
      "query=" .. tostring(query or ""),
    }, timeout_from(opts), "gh graphql query")
  end

  function handle.graphql_mutation(query, fields, opts)
    local argv = {
      "gh",
      "api",
      "graphql",
      "-f",
      "query=" .. tostring(query or ""),
    }
    append_fields(argv, fields)
    return handle._exec(argv, timeout_from(opts), "gh graphql mutation")
  end

  function handle.issue_list_open(repo, opts)
    return handle._exec({
      "gh",
      "api",
      "--paginate",
      "--slurp",
      open_list_path(repo, "issues"),
    }, timeout_from(opts), "gh issue list")
  end

  function handle.pr_list_open(repo, opts)
    return handle._exec({
      "gh",
      "api",
      "--paginate",
      "--slurp",
      open_list_path(repo, "pulls"),
    }, timeout_from(opts), "gh pr list")
  end

  function handle.issue_assign(repo, issue_number, login, opts)
    return handle._exec(issue_edit_assignee_argv(repo, issue_number, "--add-assignee", login), timeout_from(opts), "gh issue assign")
  end

  function handle.issue_unassign(repo, issue_number, login, opts)
    return handle._exec(issue_edit_assignee_argv(repo, issue_number, "--remove-assignee", login), timeout_from(opts), "gh issue unassign")
  end

  function handle.issue_create(repo, title, body_file, labels, assignees, opts)
    local argv = {
      "gh",
      "issue",
      "create",
      "--repo",
      tostring(repo),
      "--title",
      tostring(title),
      "--body-file",
      tostring(body_file),
    }
    append_labels(argv, labels)
    append_assignees(argv, assignees)
    return handle._exec(argv, timeout_from(opts), "gh issue create")
  end
end

return M
