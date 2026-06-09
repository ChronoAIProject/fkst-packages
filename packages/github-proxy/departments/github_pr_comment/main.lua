local core = require("core")

local M = {}

M.spec = {
  consumes = { "github_pr_comment_request" },
  stall_window = "30s",
}

local max_runtime_id_len = 180

local function safe_runtime_segment(value)
  local safe = tostring(value or ""):gsub("[^%w._-]", "_")
  safe = safe:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if safe == "" then
    return "empty"
  end
  return safe
end

local function pr_comment_runtime_identity(repo, number)
  local id = "comment-" .. safe_runtime_segment(repo)
    .. "-pr-" .. safe_runtime_segment(number)
  if #id > max_runtime_id_len then
    return id:sub(1, max_runtime_id_len)
  end
  return id
end

local function log_pr_outbound(mode, repo, pr_number, dedup_key, outcome_field)
  local fields = {
    "github-proxy",
    "tag=OUTBOUND",
    "mode=" .. tostring(mode or ""),
    "repo=" .. tostring(repo or ""),
    "pr=" .. tostring(pr_number or ""),
    "dedup_key=" .. tostring(dedup_key or ""),
  }
  if outcome_field ~= nil and outcome_field ~= "" then
    table.insert(fields, tostring(outcome_field))
  end
  log.info(table.concat(fields, " "))
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
  if payload.pr_number == nil or payload.body == nil or payload.dedup_key == nil then
    log.warn("github-proxy: comment request missing pr_number, body, or dedup_key")
    return
  end

  if core.read_env("FKST_GITHUB_WRITE") ~= "1" then
    log_pr_outbound("dry-run", repo, payload.pr_number, payload.dedup_key, "reason=FKST_GITHUB_WRITE!=1")
    log.info("github-proxy dry-run: would comment on " .. repo .. "#" .. tostring(payload.pr_number))
    return
  end
  local bot_login = core.assert_trusted_bot_configured()

  local runtime_id = pr_comment_runtime_identity(repo, payload.pr_number)
  with_lock("github-proxy/" .. runtime_id, function()
    local view = core.gh_exec(core.gh_pr_view_comments_cmd(repo, payload.pr_number), 30, "gh pr view")
    if core.has_trusted_marker(core.parse_issue_comments(view.stdout), payload.dedup_key, bot_login) then
      log.info("github-proxy: comment marker already present")
      return
    end

    local body = tostring(payload.body) .. "\n\n" .. core.comment_marker(payload.dedup_key) .. "\n"
    local path = "/tmp/fkst-github-proxy-" .. runtime_id .. ".md"
    file.write(path, body)
    core.gh_exec(core.gh_pr_comment_cmd(repo, payload.pr_number, path), 30, "gh pr comment")
    log_pr_outbound("real", repo, payload.pr_number, payload.dedup_key, "result=commented")
  end)
end

return M
