local shell = require("std.github.shell")

local M = {}

local function repo_owner(repo) return tostring(repo or ""):match("^([^/]+)/") end

local function is_positive_number(value)
  local number = tonumber(value)
  return number ~= nil and number >= 1 and number % 1 == 0 and number <= 2147483647
end

local function assert_branch(value, label)
  if not shell.is_git_ref_safe(value) then
    error("std.github: invalid " .. tostring(label or "branch"))
  end
end

local function assert_number(value, label)
  if not is_positive_number(value) then
    error("std.github: invalid " .. tostring(label or "number"))
  end
end

local function open_issues_argv(repo)
  return { "gh", "api", "--paginate", "--slurp", "repos/" .. tostring(repo) .. "/issues?state=open&per_page=100" }
end

local function open_prs_argv(repo)
  return { "gh", "api", "--paginate", "--slurp", "repos/" .. tostring(repo) .. "/pulls?state=open&per_page=100" }
end

local function open_prs_for_head_argv(repo, branch, base_branch)
  assert_branch(branch, "branch")
  if base_branch ~= nil then
    assert_branch(base_branch, "base branch")
  end
  local owner = repo_owner(repo)
  local head_filter = owner ~= nil and (owner .. ":" .. tostring(branch)) or tostring(branch)
  local query = "repos/" .. tostring(repo) .. "/pulls?state=open&head=" .. shell.url_encode(head_filter) .. "&per_page=100"
  if base_branch ~= nil then
    query = query .. "&base=" .. shell.url_encode(base_branch)
  end
  return { "gh", "api", "--paginate", "--slurp", query }
end

local function pr_create_argv(repo, branch, base_branch, title, body_file)
  assert_branch(branch, "branch")
  if base_branch ~= nil then
    assert_branch(base_branch, "base branch")
  end
  local argv = { "gh", "pr", "create", "--repo", tostring(repo), "--head", tostring(branch) }
  if base_branch ~= nil then
    table.insert(argv, "--base")
    table.insert(argv, tostring(base_branch))
  end
  table.insert(argv, "--title")
  table.insert(argv, tostring(title))
  table.insert(argv, "--body-file")
  table.insert(argv, tostring(body_file))
  return argv
end

local function pr_rest_argv(repo, pr_number)
  assert_number(pr_number, "PR number")
  return { "gh", "api", "repos/" .. tostring(repo) .. "/pulls/" .. tostring(pr_number) }
end

local function issue_comments_argv(repo, number)
  assert_number(number, "issue number")
  return { "gh", "api", "--paginate", "--slurp", "repos/" .. tostring(repo) .. "/issues/" .. tostring(number) .. "/comments?per_page=100" }
end

local function issue_comment_argv(kind, repo, number, body_file)
  assert_number(number, kind .. " number")
  return { "gh", kind, "comment", tostring(number), "--repo", tostring(repo), "--body-file", tostring(body_file) }
end

local function label_list_argv(repo)
  return { "gh", "label", "list", "--repo", tostring(repo), "--limit", "1000", "--json", "name" }
end

local function label_create_argv(repo, label, color)
  return { "gh", "label", "create", tostring(label), "--repo", tostring(repo), "--color", tostring(color or "ededed") }
end

local function label_edit_argv(kind, repo, number, add_labels, remove_labels)
  assert_number(number, kind .. " number")
  local argv = { "gh", kind, "edit", tostring(number), "--repo", tostring(repo) }
  for _, label in ipairs(add_labels or {}) do
    table.insert(argv, "--add-label")
    table.insert(argv, tostring(label))
  end
  for _, label in ipairs(remove_labels or {}) do
    table.insert(argv, "--remove-label")
    table.insert(argv, tostring(label))
  end
  return argv
end

function M.install(handle)
  function handle.list_open_issues(repo, timeout)
    return handle._exec(open_issues_argv(repo), timeout or 30, "gh issue list")
  end

  function handle.list_open_prs(repo, timeout)
    return handle._exec(open_prs_argv(repo), timeout or 30, "gh pr list")
  end

  function handle.find_open_pr_for_head(repo, branch, base_branch, timeout)
    return handle._exec(open_prs_for_head_argv(repo, branch, base_branch), timeout or 30, "gh pr list --head")
  end

  function handle.create_pr(repo, branch, base_branch, title, body_file, timeout)
    return handle._exec(pr_create_argv(repo, branch, base_branch, title, body_file), timeout or 60, "gh pr create")
  end

  function handle.view_pr_rest(repo, pr_number, timeout)
    return handle._exec(pr_rest_argv(repo, pr_number), timeout or 30, "gh PR REST view")
  end

  function handle.view_issue_comments(repo, issue_number, timeout)
    return handle._exec(issue_comments_argv(repo, issue_number), timeout or 30, "gh issue REST comments")
  end

  function handle.view_pr_comments(repo, pr_number, timeout)
    return handle._exec(issue_comments_argv(repo, pr_number), timeout or 30, "gh PR REST comments")
  end

  function handle.comment_issue(repo, issue_number, body_file, timeout)
    return handle._exec(issue_comment_argv("issue", repo, issue_number, body_file), timeout or 30, "gh issue comment")
  end

  function handle.comment_pr(repo, pr_number, body_file, timeout)
    return handle._exec(issue_comment_argv("pr", repo, pr_number, body_file), timeout or 30, "gh pr comment")
  end

  function handle.list_repo_labels(repo, timeout)
    return handle._exec(label_list_argv(repo), timeout or 30, "gh label list")
  end

  function handle.create_label(repo, label, color, timeout)
    return handle._exec(label_create_argv(repo, label, color), timeout or 30, "gh label create")
  end

  function handle.edit_issue_labels(repo, issue_number, add_labels, remove_labels, timeout)
    return handle._exec(label_edit_argv("issue", repo, issue_number, add_labels, remove_labels), timeout or 30, "gh issue edit")
  end

  function handle.edit_pr_labels(repo, pr_number, add_labels, remove_labels, timeout)
    return handle._exec(label_edit_argv("pr", repo, pr_number, add_labels, remove_labels), timeout or 30, "gh pr edit")
  end
end

return M
