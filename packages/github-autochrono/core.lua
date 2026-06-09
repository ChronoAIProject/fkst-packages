local M = {}

local max_source_text_ref_len = 500
local untrusted_source_begin = "BEGIN UNTRUSTED SOURCE DATA"
local untrusted_source_end = "END UNTRUSTED SOURCE DATA"
local allowed_env = {
  FKST_RUNTIME_ROOT = true,
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function decimal_checksum(value)
  local hash = 2166136261
  local text = tostring(value or "")
  for i = 1, #text do
    hash = (hash * 16777619 + text:byte(i)) % 4294967291
  end
  return string.format("%010d", hash)
end

local function safe_segment(value)
  local text = tostring(value or ""):gsub("[^%w%._%-]", "-"):gsub("%-+", "-")
  text = text:gsub("^%-+", ""):gsub("%-+$", "")
  if text == "" then
    text = "empty"
  end
  if #text > 80 then
    text = text:sub(1, 80):gsub("%-+$", "")
  end
  return text
end

local function runtime_root_path(runtime_root)
  local root = trim(runtime_root)
  if root == "" or root:find("[\r\n]") ~= nil then
    error("github-autochrono glue: invalid FKST_RUNTIME_ROOT")
  end
  return root:gsub("/+$", "")
end

local function shell_single_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.read_env_command(name)
  if not allowed_env[name] then
    error("github-autochrono glue: env name is not allowed")
  end
  return 'printf %s "$' .. name .. '"'
end

function M.read_env(name, exec)
  local run = exec or exec_sync
  if type(run) ~= "function" then
    return nil
  end
  local ok, out = pcall(run, M.read_env_command(name))
  if not ok or type(out) ~= "table" or out.exit_code ~= 0 or out.stdout == "" then
    return nil
  end
  return out.stdout
end

local function require_field(payload, name)
  local value = payload[name]
  if value == nil or value == "" then
    error("github-autochrono glue: missing " .. name)
  end
  return value
end

local function require_source_ref(payload)
  local source_ref = require_field(payload, "source_ref")
  if type(source_ref) ~= "table" or source_ref.kind == nil or source_ref.ref == nil then
    error("github-autochrono glue: invalid source_ref")
  end
  return source_ref
end

local function render_comments(comments)
  local lines = {}
  for index, comment in ipairs(comments or {}) do
    if type(comment) == "table" and comment.body ~= nil then
      local author = "unknown"
      if type(comment.author) == "table" and comment.author.login ~= nil then
        author = tostring(comment.author.login)
      elseif comment.author_login ~= nil then
        author = tostring(comment.author_login)
      end
      table.insert(lines, "Comment #" .. tostring(index) .. " by " .. author .. ":")
      table.insert(lines, tostring(comment.body))
      table.insert(lines, "")
    elseif type(comment) == "string" then
      table.insert(lines, "Comment #" .. tostring(index) .. ":")
      table.insert(lines, comment)
      table.insert(lines, "")
    end
  end
  if #lines > 0 then
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

local function render_issue_source_text(stdout)
  local decoded = json.decode(stdout or "{}")
  local comments = render_comments(decoded.comments)
  local lines = {
    untrusted_source_begin,
    "GitHub issue title:",
    tostring(decoded.title or ""),
    "",
    "GitHub issue body:",
    tostring(decoded.body or ""),
  }
  if comments ~= "" then
    table.insert(lines, "")
    table.insert(lines, "GitHub issue comments:")
    table.insert(lines, comments)
  end
  table.insert(lines, untrusted_source_end)
  return table.concat(lines, "\n")
end

function M.gh_issue_view_source_cmd(repo, issue_number)
  return "gh issue view " .. shell_single_quote(issue_number)
    .. " --repo " .. shell_single_quote(repo)
    .. " --json title,body,comments"
end

function M.write_issue_source_snapshot(runtime_root, repo, issue_number, updated_at, stdout)
  local root = runtime_root_path(runtime_root)
  local path = "/tmp/fkst-github-autochrono-source-issue-"
    .. safe_segment(repo:gsub("/", "-"))
    .. "-"
    .. safe_segment(issue_number)
    .. "-"
    .. decimal_checksum(root .. "#" .. tostring(repo) .. "#" .. tostring(issue_number) .. "#" .. tostring(updated_at))
    .. ".txt"
  if #path > max_source_text_ref_len then
    error("github-autochrono glue: source snapshot path is too long")
  end
  file.write(path, render_issue_source_text(stdout))
  return path
end

function M.entity_to_issue(payload)
  if type(payload) ~= "table" then
    error("github-autochrono glue: payload must be a table")
  end
  if payload.schema ~= "github-proxy.v1" then
    error("github-autochrono glue: unsupported entity schema")
  end
  if payload.type ~= "issue" then
    error("github-autochrono glue: entity is not an issue")
  end

  return {
    schema = "autochrono.issue.v1",
    repo = require_field(payload, "repo"),
    issue_number = require_field(payload, "number"),
    title = require_field(payload, "title"),
    url = require_field(payload, "url"),
    state = require_field(payload, "state"),
    updated_at = require_field(payload, "updated_at"),
    source_ref = require_source_ref(payload),
    source_text_ref = payload.source_text_ref,
    dedup_key = require_field(payload, "dedup_key"),
  }
end

function M.reply_to_comment_request(payload)
  if type(payload) ~= "table" then
    error("github-autochrono glue: payload must be a table")
  end
  if payload.schema ~= "autochrono.reply.v1" then
    error("github-autochrono glue: unsupported reply schema")
  end

  return {
    schema = "github-proxy.v1",
    repo = require_field(payload, "repo"),
    issue_number = require_field(payload, "issue_number"),
    body = require_field(payload, "body"),
    dedup_key = require_field(payload, "dedup_key"),
    source_ref = require_source_ref(payload),
  }
end

return M
