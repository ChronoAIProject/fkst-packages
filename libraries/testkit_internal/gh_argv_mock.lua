local M = {}
local legacy_command_renderers = require("testkit_internal.legacy_command_renderers")

local function shell_single_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function strip_simple_shell_quotes(command)
  local stripped = tostring(command or ""):gsub("'([^']*)'", "%1")
  return stripped
end

local function shell_quote_argv(value)
  local text = tostring(value or "")
  if text:find("^[%w_%-%./:=]+$") ~= nil then
    return text
  end
  return "'" .. text:gsub("'", "'\"'\"'") .. "'"
end

local function render_argv(values)
  local parts = {}
  for _, value in ipairs(values or {}) do
    table.insert(parts, shell_quote_argv(value))
  end
  return table.concat(parts, " ")
end

local function call_argv_rendered(call)
  local values = {}
  local program = (call or {}).program
  if program ~= nil and tostring(program) ~= "" then
    table.insert(values, tostring(program))
  end
  for _, arg in ipairs((call or {}).args or {}) do
    table.insert(values, tostring(arg))
  end
  return render_argv(values)
end

local function find_with_token_boundary(haystack, needle)
  local start_index, end_index = tostring(haystack or ""):find(tostring(needle or ""), 1, true)
  if start_index == nil then
    return false
  end
  local next_char = tostring(haystack or ""):sub(end_index + 1, end_index + 1)
  return next_char == "" or next_char:match("%s") ~= nil
end

local function strip_single_quotes_around_tokens(value)
  return tostring(value or ""):gsub("'([^'%s]+)'", "%1")
end

local function append_pr_list_query_order_permutation(patterns, command)
  local prefix, base = tostring(command or ""):match("^(gh api %-%-paginate %-%-slurp '?repos/[^']-/pulls%?state=open&head=[^&']+)&base=([^&']+)&per_page=100'?$")
  if prefix ~= nil then
    table.insert(patterns, prefix .. "&per_page=100&base=" .. base)
  end
end

local function append_render_permutations(patterns, command)
  local text = tostring(command or "")
  if text:match("^gh api %-%-include '") ~= nil
    or text:match("^gh api %-%-method [^ ]+ %-%-include '") ~= nil then
    return
  end
  local unquoted = strip_simple_shell_quotes(text)
  if unquoted ~= text then
    table.insert(patterns, unquoted)
  end
  append_pr_list_query_order_permutation(patterns, text)
  append_pr_list_query_order_permutation(patterns, unquoted)
  if unquoted:find("refs/remotes/origin/", 1, true) ~= nil then
    table.insert(patterns, (unquoted:gsub("refs/remotes/origin/", "refs/remotes/'origin'/'")))
  end
  if unquoted:find("refs/heads/", 1, true) ~= nil then
    table.insert(patterns, (unquoted:gsub("refs/heads/", "refs/heads/'")))
  end
  local first, rest = text:match("^(.-)%s+&&%s+(.*)$")
  if first ~= nil then
    table.insert(patterns, first)
    table.insert(patterns, strip_simple_shell_quotes(first))
    table.insert(patterns, rest)
    table.insert(patterns, strip_simple_shell_quotes(rest))
  end
  for segment in text:gmatch("[^;]+") do
    local trimmed = segment:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed ~= text and trimmed:find("%s") ~= nil then
      table.insert(patterns, trimmed)
      table.insert(patterns, strip_simple_shell_quotes(trimmed))
    end
  end
  local json_fields = text:match("^%-%-json ([^'].-)$")
  if json_fields ~= nil then
    table.insert(patterns, "--json " .. shell_single_quote(json_fields))
  end
  local quoted_json_fields = text:match("^%-%-json '([^']+)'$")
  if quoted_json_fields ~= nil then
    table.insert(patterns, "--json " .. quoted_json_fields)
  end
end

local function unique(values)
  local out = {}
  local seen = {}
  for _, value in ipairs(values or {}) do
    if type(value) == "string" and value ~= "" and not seen[value] then
      table.insert(out, value)
      seen[value] = true
    end
  end
  return out
end

function M.argv_rendered(command)
  return strip_simple_shell_quotes(command)
end

function M.call_rendered(call)
  local rendered = tostring((call or {}).rendered or "")
  if rendered ~= "" then
    return rendered
  end
  return call_argv_rendered(call)
end

function M.call_contains(call, needle)
  local rendered = tostring((call or {}).rendered or "")
  local argv_rendered = call_argv_rendered(call)
  local expected = tostring(needle or "")
  local unquoted_rendered = strip_simple_shell_quotes(rendered)
  local unquoted_argv_rendered = strip_simple_shell_quotes(argv_rendered)
  local unquoted_expected = strip_simple_shell_quotes(expected)
  local token_unquoted_expected = strip_single_quotes_around_tokens(expected)
  local expected_ends_with_quoted_token = expected:match("'[^']+'$") ~= nil
  local token_unquoted_match = false
  if token_unquoted_expected ~= expected then
    if expected_ends_with_quoted_token then
      token_unquoted_match = find_with_token_boundary(rendered, token_unquoted_expected)
        or find_with_token_boundary(unquoted_rendered, token_unquoted_expected)
        or find_with_token_boundary(argv_rendered, token_unquoted_expected)
        or find_with_token_boundary(unquoted_argv_rendered, token_unquoted_expected)
    else
      token_unquoted_match = rendered:find(token_unquoted_expected, 1, true) ~= nil
        or unquoted_rendered:find(token_unquoted_expected, 1, true) ~= nil
        or argv_rendered:find(token_unquoted_expected, 1, true) ~= nil
      or unquoted_argv_rendered:find(token_unquoted_expected, 1, true) ~= nil
    end
  end
  local normalized_rendered_match = false
  local normalized_argv_match = false
  if expected_ends_with_quoted_token then
    normalized_rendered_match = find_with_token_boundary(unquoted_rendered, unquoted_expected)
    normalized_argv_match = find_with_token_boundary(unquoted_argv_rendered, unquoted_expected)
  else
    normalized_rendered_match = rendered:find(unquoted_expected, 1, true) ~= nil
      or unquoted_rendered:find(unquoted_expected, 1, true) ~= nil
    normalized_argv_match = argv_rendered:find(unquoted_expected, 1, true) ~= nil
      or unquoted_argv_rendered:find(unquoted_expected, 1, true) ~= nil
  end
  if expected_ends_with_quoted_token then
    return rendered:find(expected, 1, true) ~= nil
      or unquoted_rendered:find(expected, 1, true) ~= nil
      or argv_rendered:find(expected, 1, true) ~= nil
      or unquoted_argv_rendered:find(expected, 1, true) ~= nil
      or normalized_rendered_match
      or normalized_argv_match
      or token_unquoted_match
  end
  return rendered:find(expected, 1, true) ~= nil
    or unquoted_rendered:find(expected, 1, true) ~= nil
    or argv_rendered:find(expected, 1, true) ~= nil
    or unquoted_argv_rendered:find(expected, 1, true) ~= nil
    or normalized_rendered_match
    or normalized_argv_match
    or token_unquoted_match
end

function M.argv_contains(call, values)
  local argv = {}
  if (call or {}).program ~= nil and tostring(call.program) ~= "" then
    table.insert(argv, tostring(call.program))
  end
  for _, arg in ipairs((call or {}).args or {}) do
    table.insert(argv, tostring(arg))
  end
  local offset = 1
  for _, expected in ipairs(values or {}) do
    local found = false
    for index = offset, #argv do
      if argv[index] == tostring(expected) then
        found = true
        offset = index + 1
        break
      end
    end
    if not found then
      return false
    end
  end
  return true
end

function M.argv_value_after(call, flag)
  local selected_flag = tostring(flag or "")
  local args = (call or {}).args or {}
  for index, arg in ipairs(args) do
    if tostring(arg) == selected_flag then
      local value = args[index + 1]
      if value ~= nil then
        return tostring(value)
      end
    end
  end
  local rendered = M.call_rendered(call)
  local single_quoted = rendered:match(selected_flag:gsub("([^%w])", "%%%1") .. "%s+'([^']+)'")
  if single_quoted ~= nil then
    return single_quoted
  end
  return rendered:match(selected_flag:gsub("([^%w])", "%%%1") .. "%s+([^%s]+)")
end

function M.count_calls(t, needle)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if M.call_contains(call, needle) then
      count = count + 1
    end
  end
  return count
end

local function append_gh_mock_patterns(patterns, command)
  local text = tostring(command or "")
  if text:find("gh ", 1, true) == nil then
    return
  end
  table.insert(patterns, strip_simple_shell_quotes(text))
  local issue_number, repo, issue_fields = text:match("^gh issue view '([^']+)' %-%-repo '([^']+)' %-%-json ([^ ]+)$")
  if issue_number ~= nil then
    table.insert(patterns, "gh issue view " .. issue_number .. " --repo " .. repo .. " --json '" .. issue_fields .. "'")
    return
  end
  local issue_number_plain, repo_plain, issue_fields_plain = text:match("^gh issue view ([^ ]+) %-%-repo ([^ ]+) %-%-json ([^ ]+)$")
  if issue_number_plain ~= nil then
    table.insert(patterns, "gh issue view " .. issue_number_plain .. " --repo " .. repo_plain .. " --json '" .. issue_fields_plain .. "'")
    return
  end
  local pr_number, pr_repo, pr_fields = text:match("^gh pr view '([^']+)' %-%-repo '([^']+)' %-%-json ([^ ]+)$")
  if pr_number ~= nil then
    table.insert(patterns, "gh pr view " .. pr_number .. " --repo " .. pr_repo .. " --json '" .. pr_fields .. "'")
    return
  end
  local pr_number_plain, pr_repo_plain, pr_fields_plain = text:match("^gh pr view ([^ ]+) %-%-repo ([^ ]+) %-%-json ([^ ]+)$")
  if pr_number_plain ~= nil then
    table.insert(patterns, "gh pr view " .. pr_number_plain .. " --repo " .. pr_repo_plain .. " --json '" .. pr_fields_plain .. "'")
    return
  end
  local edit_number, edit_repo = text:match("^gh issue edit '([^']+)' %-%-repo '([^']+)' ")
  if edit_number ~= nil then
    table.insert(patterns, "gh issue edit " .. edit_number .. " --repo " .. edit_repo)
  end
  local list_repo, list_state, list_limit, list_fields = text:match("^gh issue list %-%-repo '([^']+)' %-%-state ([^ ]+) %-%-limit ([^ ]+) %-%-json ([^ ]+)$")
  if list_repo ~= nil then
    table.insert(patterns, "gh issue list --repo " .. list_repo .. " --state " .. list_state .. " --limit " .. list_limit .. " --json '" .. list_fields .. "'")
    table.insert(patterns, "gh issue list --repo " .. list_repo .. " --state " .. list_state .. " --limit " .. list_limit .. " --json " .. list_fields)
  end
  local search_repo, search_state, search_limit, search_query, search_fields =
    text:match("^gh issue list %-%-repo '([^']+)' %-%-state ([^ ]+) %-%-limit ([^ ]+) %-%-search '([^']+)' %-%-json ([^ ]+)$")
  if search_repo ~= nil then
    table.insert(patterns, "gh issue list --repo " .. search_repo
      .. " --state " .. search_state
      .. " --limit " .. search_limit
      .. " --search " .. shell_single_quote(search_query)
      .. " --json '" .. search_fields .. "'")
    table.insert(patterns, "gh issue list --repo " .. search_repo
      .. " --state " .. search_state
      .. " --limit " .. search_limit
      .. " --search " .. shell_single_quote(search_query)
      .. " --json " .. search_fields)
  end
  local pr_list_repo, pr_list_state, pr_list_limit, pr_list_fields = text:match("^gh pr list %-%-repo '([^']+)' %-%-state ([^ ]+) %-%-limit ([^ ]+) %-%-json ([^ ]+)$")
  if pr_list_repo ~= nil then
    table.insert(patterns, "gh pr list --repo " .. pr_list_repo .. " --state " .. pr_list_state .. " --limit " .. pr_list_limit .. " --json '" .. pr_list_fields .. "'")
  end
  local api_path = text:match("^gh api '([^']+)'$")
  if api_path ~= nil then
    table.insert(patterns, "gh api " .. api_path)
  end
  local comments_path = text:match("^gh api %-%-paginate %-%-slurp '([^']+)'$")
  if comments_path ~= nil then
    table.insert(patterns, "gh api --paginate --slurp " .. comments_path)
  end
  local api_method_simple, api_method_simple_path = text:match("^gh api %-%-method ([^ ]+) ([^ '][^ ]*)$")
  if api_method_simple_path ~= nil then
    table.insert(patterns, "gh api --method " .. api_method_simple .. " " .. shell_single_quote(api_method_simple_path))
  end
  local jq_path, jq_expr = text:match("^gh api '([^']+)' %-%-jq '([^']+)'$")
  if jq_path ~= nil then
    table.insert(patterns, "gh api " .. jq_path .. " --jq " .. jq_expr)
    table.insert(patterns, "gh api " .. jq_path .. " --jq '" .. jq_expr .. "'")
  end
  local method, method_path = text:match("^gh api %-%-method ([^ ]+) '([^']+)'$")
  if method_path ~= nil then
    table.insert(patterns, "gh api --method " .. method .. " " .. method_path)
  end
  local input_method, input_path, input_file = text:match("^gh api %-%-method ([^ ]+) '([^']+)' %-%-input '([^']+)'")
  if input_path ~= nil then
    table.insert(patterns, "gh api --method " .. input_method .. " " .. input_path .. " --input " .. input_file)
  end
  local input_method_prefix, input_path_prefix, input_file_prefix = text:match("^gh api %-%-method ([^ ]+) '([^']+)' %-%-input '([^']*)$")
  if input_path_prefix ~= nil then
    table.insert(patterns, "gh api --method " .. input_method_prefix .. " " .. input_path_prefix .. " --input " .. input_file_prefix)
  end
  local field_method, field_path = text:match("^gh api %-%-method ([^ ]+) '([^']+)' %-f ")
  if field_path ~= nil then
    table.insert(patterns, "gh api --method " .. field_method .. " " .. field_path .. " -f ")
    table.insert(patterns, "gh api --method " .. field_method .. " " .. shell_single_quote(field_path) .. " -f ")
  end
  local field_method_full, field_path_full, fields_tail = text:match("^gh api %-%-method ([^ ]+) '([^']+)' (%-f .*)$")
  if field_path_full ~= nil then
    local unquoted_fields = fields_tail:gsub("'([^']*)'", "%1")
    table.insert(patterns, "gh api --method " .. field_method_full .. " " .. field_path_full .. " " .. unquoted_fields)
    table.insert(patterns, "gh api --method " .. field_method_full .. " " .. shell_single_quote(field_path_full) .. " " .. unquoted_fields)
  end
  local pr_comment_number, pr_comment_repo, pr_comment_file = text:match("^gh pr comment '([^']+)' %-%-repo '([^']+)' %-%-body%-file '([^']+)'")
  if pr_comment_number ~= nil then
    table.insert(patterns, "gh pr comment " .. pr_comment_number .. " --repo " .. pr_comment_repo .. " --body-file " .. pr_comment_file)
  end
  local pr_comment_number_prefix, pr_comment_repo_prefix, pr_comment_file_prefix = text:match("^gh pr comment '([^']+)' %-%-repo '([^']+)' %-%-body%-file '([^']*)$")
  if pr_comment_number_prefix ~= nil then
    table.insert(patterns, "gh pr comment " .. pr_comment_number_prefix .. " --repo " .. pr_comment_repo_prefix .. " --body-file " .. pr_comment_file_prefix)
  end
  local issue_comment_number, issue_comment_repo, issue_comment_file = text:match("^gh issue comment '([^']+)' %-%-repo '([^']+)' %-%-body%-file '([^']+)'")
  if issue_comment_number ~= nil then
    table.insert(patterns, "gh issue comment " .. issue_comment_number .. " --repo " .. issue_comment_repo .. " --body-file " .. issue_comment_file)
  end
  local issue_comment_number_prefix, issue_comment_repo_prefix, issue_comment_file_prefix = text:match("^gh issue comment '([^']+)' %-%-repo '([^']+)' %-%-body%-file '([^']*)$")
  if issue_comment_number_prefix ~= nil then
    table.insert(patterns, "gh issue comment " .. issue_comment_number_prefix .. " --repo " .. issue_comment_repo_prefix .. " --body-file " .. issue_comment_file_prefix)
  end
  local pr_ready_number, pr_ready_repo = text:match("^gh pr ready '([^']+)' %-%-repo '([^']+)'$")
  if pr_ready_number ~= nil then
    table.insert(patterns, "gh pr ready " .. pr_ready_number .. " --repo " .. pr_ready_repo)
  end
  local pr_close_number, pr_close_repo = text:match("^gh pr close '([^']+)' %-%-repo '([^']+)'$")
  if pr_close_number ~= nil then
    table.insert(patterns, "gh pr close " .. pr_close_number .. " --repo " .. pr_close_repo)
  end
  local issue_close_number, issue_close_repo, issue_close_reason =
    text:match("^gh issue close '([^']+)' %-%-repo '([^']+)' %-%-reason '([^']+)'$")
  if issue_close_number ~= nil then
    table.insert(patterns, "gh issue close " .. issue_close_number .. " --repo " .. issue_close_repo .. " --reason " .. issue_close_reason)
  end
  local duplicate_close_number, duplicate_close_repo, duplicate_of =
    text:match("^gh issue close '([^']+)' %-%-repo '([^']+)' %-%-duplicate%-of '([^']+)'$")
  if duplicate_close_number ~= nil then
    table.insert(patterns, "gh issue close " .. duplicate_close_number .. " --repo " .. duplicate_close_repo .. " --duplicate-of " .. duplicate_of)
  end
  local diff_number, diff_repo = text:match("^gh pr diff '([^']+)' %-%-repo '([^']+)'$")
  if diff_number ~= nil then
    table.insert(patterns, "gh pr diff " .. diff_number .. " --repo " .. diff_repo)
  end
  local diff_name_number, diff_name_repo = text:match("^gh pr diff '([^']+)' %-%-repo '([^']+)' %-%-name%-only$")
  if diff_name_number ~= nil then
    table.insert(patterns, "gh pr diff " .. diff_name_number .. " --repo " .. diff_name_repo .. " --name-only")
  end
end

local function append_git_mock_patterns(patterns, command)
  local text = tostring(command or "")
  if text:find("git ", 1, true) == nil then
    return
  end
  local unquoted = strip_simple_shell_quotes(text)
  table.insert(patterns, unquoted)
  if unquoted:find("refs/remotes/origin/", 1, true) ~= nil then
    table.insert(patterns, (unquoted:gsub("refs/remotes/origin/", "refs/remotes/'origin'/'")))
  end
  if unquoted:find("refs/heads/", 1, true) ~= nil then
    table.insert(patterns, (unquoted:gsub("refs/heads/", "refs/heads/'")))
  end
  local fetch_remote, fetch_ref = text:match("^git fetch '([^']+)' '([^']+)'$")
  if fetch_remote ~= nil then
    table.insert(patterns, "git fetch " .. fetch_remote .. " " .. fetch_ref)
  end
  if text == "git rev-parse --verify FETCH_HEAD^{commit}" then
    table.insert(patterns, "git rev-parse --verify 'FETCH_HEAD^{commit}'")
  elseif text == "git rev-parse --verify 'FETCH_HEAD^{commit}'" then
    table.insert(patterns, "git rev-parse --verify FETCH_HEAD^{commit}")
  end
  local rev_remote, rev_branch = text:match("^git rev%-parse %-%-verify refs/remotes/'([^']+)'/'([^']+)'%^{commit}$")
  if rev_remote ~= nil then
    table.insert(patterns, "git rev-parse --verify refs/remotes/" .. rev_remote .. "/" .. rev_branch .. "^{commit}")
    table.insert(patterns, "git rev-parse --verify 'refs/remotes/" .. rev_remote .. "/" .. rev_branch .. "^{commit}'")
  end
  local quoted_rev_ref = text:match("^git rev%-parse %-%-verify 'refs/remotes/([^']+)%^{commit}'$")
  if quoted_rev_ref ~= nil then
    local remote, branch = quoted_rev_ref:match("^([^/]+)/(.+)$")
    if remote ~= nil and branch ~= nil then
      table.insert(patterns, "git rev-parse --verify refs/remotes/'" .. remote .. "'/'" .. branch .. "'^{commit}")
    end
  end
  local ls_remote, ls_branch = text:match("^git ls%-remote '([^']+)' refs/heads/'([^']+)'$")
  if ls_remote ~= nil then
    table.insert(patterns, "git ls-remote " .. ls_remote .. " refs/heads/" .. ls_branch)
  end
  local worktree, branch = text:match("^git %-C '([^']+)' rev%-parse %-%-abbrev%-ref HEAD$")
  if worktree ~= nil then
    table.insert(patterns, "git -C " .. worktree .. " rev-parse --abbrev-ref HEAD")
  end
  local bare_branch = text:match("^git rev%-parse %-%-abbrev%-ref HEAD$")
  if bare_branch ~= nil then
    table.insert(patterns, "git rev-parse --abbrev-ref HEAD")
  end
end

local function install_command_shim(t)
  if t._gh_argv_mock_shim_installed == true then
    return
  end
  local raw_mock_command = t.mock_command
  t.mock_command = function(command, result)
    local patterns = { command }
    append_render_permutations(patterns, command)
    append_gh_mock_patterns(patterns, command)
    append_git_mock_patterns(patterns, command)
    for _, pattern in ipairs(unique(patterns)) do
      raw_mock_command(pattern, result)
    end
  end
  t._gh_argv_mock_shim_installed = true
end

local legacy_renderers = legacy_command_renderers.new({
  shell_single_quote = shell_single_quote,
  render_argv = render_argv,
})

function M.install(t, core)
  install_command_shim(t)
  legacy_renderers.install(core)
end

return M
