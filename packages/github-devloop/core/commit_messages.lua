local M = {}
local root_ref = nil

local max_commit_message_bytes = 200

local function root()
  return root_ref or M
end

local function bytes(...)
  return string.char(...)
end

local commit_prefixes = {
  implement = bytes(0xe8, 0x87, 0xaa, 0xe6, 0xb2, 0xbb, 0xe5, 0xae, 0x9e, 0xe7, 0x8e, 0xb0),
  fix = bytes(0xe8, 0x87, 0xaa, 0xe6, 0xb2, 0xbb, 0xe4, 0xbf, 0xae, 0xe5, 0xa4, 0x8d),
}

local function utf8_sequence_length(byte)
  if byte == nil then
    return nil
  end
  if byte < 0x80 then
    return 1
  end
  if byte >= 0xc2 and byte <= 0xdf then
    return 2
  end
  if byte >= 0xe0 and byte <= 0xef then
    return 3
  end
  if byte >= 0xf0 and byte <= 0xf4 then
    return 4
  end
  return nil
end

local function valid_utf8_sequence(value, start, len)
  if start + len - 1 > #value then
    return false
  end
  for offset = 1, len - 1 do
    local byte = value:byte(start + offset)
    if byte == nil or byte < 0x80 or byte > 0xbf then
      return false
    end
  end
  return true
end

local function utf8_safe_prefix(value, max_bytes)
  local text = tostring(value or "")
  local limit = tonumber(max_bytes or max_commit_message_bytes) or max_commit_message_bytes
  if limit <= 0 then
    return ""
  end

  local index = 1
  local last = 0
  while index <= #text do
    local len = utf8_sequence_length(text:byte(index))
    if len == nil or not valid_utf8_sequence(text, index, len) then
      break
    end
    if index + len - 1 > limit then
      break
    end
    last = index + len - 1
    index = index + len
  end
  return text:sub(1, last)
end

local function issue_subject(prefix, issue_number, title)
  local base = tostring(prefix) .. " #" .. tostring(issue_number)
  local full = base
  local normalized_title = tostring(title or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if normalized_title ~= "" then
    full = base .. ": " .. normalized_title
  end
  local bounded = utf8_safe_prefix(full, max_commit_message_bytes)
  if bounded ~= "" then
    return bounded
  end
  return utf8_safe_prefix(base, max_commit_message_bytes)
end

local function fetch_issue_title(repo, issue_number)
  local core = root()
  if issue_number == nil then
    return nil
  end
  local result = exec_sync({ cmd = core.gh_issue_view_title_cmd(repo, issue_number), timeout = 30 })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    return nil
  end
  local ok, decoded = pcall(json.decode, result.stdout or "{}")
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  if type(decoded.title) ~= "string" then
    return nil
  end
  return decoded.title
end

function M.github_issue_commit_message(kind, repo, issue_number)
  local prefix = commit_prefixes[tostring(kind or "")]
  if prefix == nil then
    error("github-devloop: invalid commit message kind")
  end
  if issue_number == nil then
    return utf8_safe_prefix(tostring(prefix), max_commit_message_bytes)
  end
  return issue_subject(prefix, issue_number, fetch_issue_title(repo, issue_number))
end

function M._utf8_safe_commit_prefix(value, max_bytes)
  return utf8_safe_prefix(value, max_bytes)
end

function M._issue_commit_subject(kind, issue_number, title)
  local prefix = commit_prefixes[tostring(kind or "")]
  if prefix == nil then
    error("github-devloop: invalid commit message kind")
  end
  return issue_subject(prefix, issue_number, title)
end

function M.install(target)
  root_ref = target
  target.github_issue_commit_message = M.github_issue_commit_message
  target._utf8_safe_commit_prefix = M._utf8_safe_commit_prefix
  target._issue_commit_subject = M._issue_commit_subject
end

return M
