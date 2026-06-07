local core = require("core")

local M = {}

M.spec = {
  consumes = { "github_pr_comment_request" },
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

local function runtime_identity(repo, pr_number)
  local id = "comment-" .. safe_segment(repo) .. "-pr-" .. safe_segment(pr_number)
  if #id > MAX_RUNTIME_ID_LEN then
    return id:sub(1, MAX_RUNTIME_ID_LEN)
  end
  return id
end

local function temp_body_file(repo, pr_number)
  return "/tmp/fkst-github-proxy-" .. runtime_identity(repo, pr_number) .. ".md"
end

local function lock_name(repo, pr_number)
  return "github-proxy/" .. runtime_identity(repo, pr_number)
end

function pipeline(event)
  local payload = event.payload or {}
  local repo = payload.repo
  if repo == nil or repo == "" then
    repo = core.read_env("FKST_GITHUB_REPO")
  end
  if repo == nil or repo == "" then
    log.warn("github-proxy: PR comment request missing repo")
    return
  end
  if payload.pr_number == nil or payload.body == nil or payload.dedup_key == nil then
    log.warn("github-proxy: PR comment request missing pr_number, body, or dedup_key")
    return
  end

  if core.read_env("FKST_GITHUB_WRITE") ~= "1" then
    log.info("github-proxy dry-run: would comment on PR " .. repo .. "#" .. tostring(payload.pr_number))
    return
  end
  local bot_login = core.assert_trusted_bot_configured()

  with_lock(lock_name(repo, payload.pr_number), function()
    local view = exec_sync({ cmd = core.gh_pr_view_comments_cmd(repo, payload.pr_number), timeout = 30 })
    if view.exit_code ~= 0 then
      error("github-proxy: gh pr view failed: " .. tostring(view.stderr))
    end
    if core.has_trusted_marker(core.parse_issue_comments(view.stdout), payload.dedup_key, bot_login) then
      log.info("github-proxy: PR comment marker already present")
      return
    end

    local body = tostring(payload.body) .. "\n\n" .. core.comment_marker(payload.dedup_key) .. "\n"
    local path = temp_body_file(repo, payload.pr_number)
    file.write(path, body)
    local comment = exec_sync({ cmd = core.gh_pr_comment_cmd(repo, payload.pr_number, path), timeout = 30 })
    if comment.exit_code ~= 0 then
      error("github-proxy: gh pr comment failed: " .. tostring(comment.stderr))
    end
  end)
end

return M
