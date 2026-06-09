local core = require("core")

local M = {}

M.spec = {
  consumes = { "github_issue_comment_request" },
  stall_window = "30s",
}

local MAX_RUNTIME_ID_LEN = 180

local function safe_segment(value)
  local safe = tostring(value or ""):gsub("[^%w._-]", "_")
  safe = safe:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if safe == "" then
    return "empty"
  end
  return safe
end

local function runtime_identity(repo, issue_number)
  local id = "comment-" .. safe_segment(repo) .. "-issue-" .. safe_segment(issue_number)
  if #id > MAX_RUNTIME_ID_LEN then
    return id:sub(1, MAX_RUNTIME_ID_LEN)
  end
  return id
end

local function temp_body_file(repo, issue_number)
  return "/tmp/fkst-github-proxy-" .. runtime_identity(repo, issue_number) .. ".md"
end

local function lock_name(repo, issue_number)
  return "github-proxy/" .. runtime_identity(repo, issue_number)
end

local function should_update_existing_comment(payload, existing)
  return existing ~= nil and payload.upsert == true
end

local function existing_upsert_comment(comments, payload, bot_login)
  if payload.upsert == true then
    return core.trusted_comment_with_marker(comments, payload.upsert_marker, bot_login)
  end
  return core.trusted_marker_comment(comments, payload.dedup_key, bot_login)
end

function pipeline(event)
  local payload = event.payload or {}
  local repo = payload.repo
  if repo == nil or repo == "" then
    repo = core.read_env("FKST_GITHUB_REPO")
  end
  if repo == nil or repo == "" then
    log.warn("github-proxy: comment request missing repo")
    return
  end
  if payload.issue_number == nil or payload.dedup_key == nil then
    log.warn("github-proxy: comment request missing issue_number or dedup_key")
    return
  end

  if core.read_env("FKST_GITHUB_WRITE") ~= "1" then
    log.info("github-proxy dry-run: would comment on " .. repo .. "#" .. tostring(payload.issue_number))
    return
  end
  local bot_login = core.assert_trusted_bot_configured()

  with_lock(lock_name(repo, payload.issue_number), function()
    local view = exec_sync({ cmd = core.gh_issue_view_comments_cmd(repo, payload.issue_number), timeout = 30 })
    if view.exit_code ~= 0 then
      -- A re-derive command failure must NOT silent-ack a reliable comment request; error so
      -- delivery retries (otherwise a result marker comment could be permanently lost).
      error("github-proxy: gh issue view failed: " .. tostring(view.stderr))
    end
    local comments = core.parse_issue_comments(view.stdout)
    local existing = existing_upsert_comment(comments, payload, bot_login)
    if existing ~= nil and not should_update_existing_comment(payload, existing) then
      log.info("github-proxy: comment marker already present")
      return
    end

    if payload.body == nil then
      log.warn("github-proxy: comment request missing body")
      return
    end

    local body = tostring(payload.body) .. "\n\n" .. core.comment_marker(payload.dedup_key) .. "\n"
    local path = temp_body_file(repo, payload.issue_number)
    file.write(path, body)
    local cmd = core.gh_issue_comment_cmd(repo, payload.issue_number, path)
    local action = "comment"
    if should_update_existing_comment(payload, existing) then
      cmd = core.gh_issue_comment_edit_cmd(existing.id, path)
      action = "comment edit"
    end
    local comment = exec_sync({ cmd = cmd, timeout = 30 })
    if comment.exit_code ~= 0 then
      error("github-proxy: gh issue " .. action .. " failed: " .. tostring(comment.stderr))
    end
  end)
end

return M
