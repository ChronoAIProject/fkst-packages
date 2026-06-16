local S = {}

function S.install(M)
local max_runtime_id_len = 180
local stale_comment_target_error_class = "stale-comment-target"
local github_adapter = nil

local function safe_runtime_segment(value)
  local safe = tostring(value or ""):gsub("[^%w._-]", "_")
  safe = safe:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return safe == "" and "empty" or safe
end

local function comment_runtime_identity(repo, kind, number)
  local id = "comment-" .. safe_runtime_segment(repo)
    .. "-" .. safe_runtime_segment(kind)
    .. "-" .. safe_runtime_segment(number)
  if #id > max_runtime_id_len then
    return id:sub(1, max_runtime_id_len)
  end
  return id
end

local function comment_body(comment)
  if type(comment) == "table" then
    return tostring(comment.body or "")
  end
  return tostring(comment or "")
end

-- A GitHub App's author login is "<slug>[bot]" via the REST API but bare
-- "<slug>" via GraphQL. Strip the suffix so callers comparing against a
-- configured bot login match regardless of which API populated the field.
-- No-op for ordinary user logins (which never end in "[bot]").
local function strip_bot_login_suffix(login)
  if login == nil then
    return nil
  end
  return (tostring(login):gsub("%[bot%]$", ""))
end

local function comment_author_login(comment)
  local raw = nil
  if type(comment) == "table" then
    if comment.author_login ~= nil then
      raw = comment.author_login
    elseif type(comment.author) == "table" and comment.author.login ~= nil then
      raw = comment.author.login
    elseif type(comment.user) == "table" and comment.user.login ~= nil then
      raw = comment.user.login
    end
  end
  return strip_bot_login_suffix(raw)
end

function M._comment_body(comment)
  return comment_body(comment)
end

function M._comment_author_login(comment)
  return comment_author_login(comment)
end

function M.stale_comment_target_error_class()
  return stale_comment_target_error_class
end

function M.github_adapter()
  if github_adapter ~= nil then
    return github_adapter
  end
  if type(exec_argv) ~= "function" then
    error("github-proxy: std.github adapter requires exec_argv")
  end
  github_adapter = require("std.github").new(exec_argv)
  return github_adapter
end

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

local function rest_comment_id(comment)
  if type(comment) ~= "table" or comment.id == nil then
    return nil
  end
  local id = tostring(comment.id)
  if id == "" or id:find("^%d+$") == nil then
    return nil
  end
  return id
end

local function append_rest_comments(comments, value)
  if type(value) ~= "table" then
    return
  end
  if value.id ~= nil or value.body ~= nil or value.user ~= nil or value.author ~= nil then
    local id = comment_id(value) or rest_comment_id(value)
    if id ~= nil then
      table.insert(comments, {
        id = id,
        body = comment_body(value),
        author_login = comment_author_login(value),
      })
    end
    return
  end
  for _, item in ipairs(value) do
    append_rest_comments(comments, item)
  end
end

function M.comment_marker(dedup_key)
  return "<!-- fkst:github-proxy:comment:" .. tostring(dedup_key) .. " -->"
end

function M.has_marker(comments_text, dedup_key)
  if comments_text == nil or comments_text == "" then
    return false
  end
  return tostring(comments_text):find(M.comment_marker(dedup_key), 1, true) ~= nil
end

function M.parse_issue_comments(gh_json_stdout)
  local decoded = json.decode(gh_json_stdout or "{}")
  local comments = {}
  if decoded.comments == nil then
    append_rest_comments(comments, decoded)
    return comments
  end
  for _, comment in ipairs(decoded.comments or {}) do
    table.insert(comments, {
      id = comment_id(comment),
      body = comment_body(comment),
      author_login = comment_author_login(comment),
    })
  end
  return comments
end

function M.has_trusted_marker(comments, dedup_key, bot_login)
  if type(comments) ~= "table" then
    return false
  end
  local marker = M.comment_marker(dedup_key)
  for _, comment in ipairs(comments) do
    if comment_author_login(comment) == bot_login and comment_body(comment):find(marker, 1, true) ~= nil then
      return true
    end
  end
  return false
end

function M.has_trusted_comment_fragment(comments, fragment, bot_login)
  if type(comments) ~= "table" or type(fragment) ~= "string" or fragment == "" then
    return false
  end
  for _, comment in ipairs(comments) do
    if comment_author_login(comment) == bot_login and comment_body(comment):find(fragment, 1, true) ~= nil then
      return true
    end
  end
  return false
end

function M.trusted_comment_with_fragment(comments, fragment, bot_login)
  if type(comments) ~= "table" or type(fragment) ~= "string" or fragment == "" then
    return nil
  end
  for _, comment in ipairs(comments) do
    if comment_author_login(comment) == bot_login and comment_body(comment):find(fragment, 1, true) ~= nil then
      return comment
    end
  end
  return nil
end

local function gh_result_stderr(result)
  if type(result) ~= "table" then
    return ""
  end
  return tostring(result.stderr or "")
end

local function is_gh_not_found(result)
  local lower = gh_result_stderr(result):lower()
  if lower:find("404", 1, true) ~= nil and lower:find("not found", 1, true) ~= nil then
    return true
  end
  return lower:find("gh: not found", 1, true) ~= nil
end

local function load_comments(M, target, repo)
  return M.github_adapter().list_issue_comments(repo, target.number, {
    timeout = 30,
    context = target.view_label,
  })
end

local function parse_rest_comments(stdout)
  local ok, decoded = pcall(json.decode, stdout or "[]")
  if not ok then
    return {}
  end
  local comments = {}
  append_rest_comments(comments, decoded)
  return comments
end

local function load_rest_comments(M, target, repo)
  return M.github_adapter().list_issue_comments(repo, target.number, {
    timeout = 30,
    context = "github issue comments",
  })
end

local function trusted_rest_comment_with_fragment(M, repo, target, fragment, bot_login)
  local comments = load_rest_comments(M, target, repo)
  return M.trusted_comment_with_fragment(comments, fragment, bot_login)
end

local function edit_existing_comment(M, repo, target, path, existing, replace_marker, bot_login)
  if existing == nil or existing.id == nil then
    return false, "missing-id"
  end

  local ok, result_or_err = pcall(function()
    return M.github_adapter().edit_issue_comment(repo, existing.id, path, {
      timeout = 30,
      context = "github comment edit",
    })
  end)
  if ok then
    return true, nil, result_or_err or existing
  end

  if not is_gh_not_found(result_or_err.result) then
    error(result_or_err.message or result_or_err)
  end

  log.warn("github-proxy: gh comment edit returned 404; re-reading comments before classification")
  local comments = load_comments(M, target, repo)
  local refreshed = M.trusted_comment_with_fragment(comments, replace_marker, bot_login)
  if refreshed == nil or refreshed.id == nil then
    log.warn("github-proxy: gh comment edit target is stale: error_class=" .. stale_comment_target_error_class)
    return false, stale_comment_target_error_class
  end

  local refreshed_ok, refreshed_result_or_err = pcall(function()
    return M.github_adapter().edit_issue_comment(repo, refreshed.id, path, {
      timeout = 30,
      context = "github comment edit",
    })
  end)
  if refreshed_ok then
    return true, nil, refreshed_result_or_err or refreshed
  end
  if is_gh_not_found(refreshed_result_or_err.result) then
    log.warn("github-proxy: refreshed gh comment edit target is stale: error_class=" .. stale_comment_target_error_class)
    return false, stale_comment_target_error_class
  end
  error(refreshed_result_or_err.message or refreshed_result_or_err)
end

function M.write_comment_request(payload, target)
  local repo = payload.repo
  if repo == nil or repo == "" then
    repo = M.read_env("FKST_GITHUB_REPO")
  end
  if repo == nil or repo == "" then
    log.warn("github-proxy: comment request missing repo")
    return
  end
  if target.number == nil or payload.body == nil or payload.dedup_key == nil then
    log.warn("github-proxy: comment request missing " .. tostring(target.number_field) .. ", body, or dedup_key")
    return
  end

  if M.read_env("FKST_GITHUB_WRITE") ~= "1" then
    log.info("github-proxy dry-run: would comment on " .. repo .. "#" .. tostring(target.number))
    return
  end
  local bot_login = M.assert_trusted_bot_configured()

  local runtime_id = comment_runtime_identity(repo, target.kind, target.number)
  local written_comment = nil
  with_lock("github-proxy/" .. runtime_id, function()
    local comments = load_comments(M, target, repo)
    local replace_marker = payload.replace_marker
    local existing = nil
    if replace_marker ~= nil and tostring(replace_marker) ~= "" then
      existing = M.trusted_comment_with_fragment(comments, tostring(replace_marker), bot_login)
    elseif M.has_trusted_marker(comments, payload.dedup_key, bot_login) then
      log.info("github-proxy: comment marker already present")
      if payload.handoff ~= nil then
        written_comment = trusted_rest_comment_with_fragment(M, repo, target, M.comment_marker(payload.dedup_key), bot_login)
      end
      return
    end
    local claim_issue_number = target.kind == "issue" and target.number or payload.issue_number
    if claim_issue_number ~= nil
      and not M.verify_issue_claim_before_write(payload, repo, claim_issue_number, target.kind == "pr" and "github_pr_comment" or "github_comment") then
      return
    end

    local body = tostring(payload.body) .. "\n\n" .. M.comment_marker(payload.dedup_key) .. "\n"
    body = M.with_github_debug_stamp(body, {
      emitter = "github-proxy.comment",
      target = tostring(target.kind) .. ":" .. tostring(repo) .. "#" .. tostring(target.number),
      dedup_key = payload.dedup_key,
    })
    local path = "/tmp/fkst-github-proxy-" .. runtime_id .. ".md"
    file.write(path, body)
    local edited, edit_status, edited_comment = edit_existing_comment(M, repo, target, path, existing, tostring(replace_marker or ""), bot_login)
    if edited then
      written_comment = edited_comment
      M.invalidate_entity_after_write(repo, target.kind, target.number)
      return
    end
    if edit_status == stale_comment_target_error_class then
      log.warn("github-proxy: creating a fresh comment after stale comment edit target")
    elseif existing ~= nil then
      log.warn("github-proxy: replace marker comment missing id; creating a fresh comment")
    end
    local written = M.github_adapter().create_issue_comment(repo, target.number, path, {
      timeout = 30,
      context = target.comment_label,
    })
    if written == nil then
      error("github-proxy: comment create did not return a valid comment id")
    end
    written_comment = written
    M.invalidate_entity_after_write(repo, target.kind, target.number)
  end)
  return written_comment
end

end

return S
