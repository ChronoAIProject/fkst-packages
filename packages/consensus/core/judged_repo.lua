local strings = require("contract.strings")

local J = {}

local max_repo_len = 200
local max_path_len = 1000
local max_sha_len = 64
local max_line_number = 1000000

local function single_line_string(value, limit)
  return strings.is_bounded_string(value, limit) and tostring(value):find("%c") == nil
end

local function is_safe_absolute_path(value)
  if not single_line_string(value, max_path_len) then
    return false
  end
  local path = tostring(value)
  if path:sub(1, 1) ~= "/" or path:find("\0", 1, true) ~= nil then
    return false
  end
  if path:gsub("/+$", "") == "" then
    return false
  end
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return false
    end
  end
  return true
end

function J.is_git_sha(value)
  return type(value) == "string"
    and #value >= 7
    and #value <= max_sha_len
    and value:find("^%x+$") ~= nil
end

function J.has(proposal)
  return type(proposal) == "table" and proposal.judged_repo ~= nil
end

function J.is_valid(value)
  if value == nil then
    return true
  end
  if type(value) ~= "table" then
    return false
  end
  if value.repo ~= nil and not single_line_string(value.repo, max_repo_len) then
    return false
  end
  if value.head_sha ~= nil and not J.is_git_sha(value.head_sha) then
    return false
  end
  if value.repo_path ~= nil and not is_safe_absolute_path(value.repo_path) then
    return false
  end
  if value.repo_path == nil and value.head_sha == nil then
    return false
  end
  return value.repo ~= nil or value.repo_path ~= nil
end

function J.normalize(value)
  if not J.is_valid(value) or value == nil then
    return nil
  end
  local normalized = {}
  if value.repo ~= nil then
    normalized.repo = tostring(value.repo)
  end
  if value.head_sha ~= nil then
    normalized.head_sha = tostring(value.head_sha):lower()
  end
  if value.repo_path ~= nil then
    normalized.repo_path = tostring(value.repo_path):gsub("/+$", "")
    if normalized.repo_path == "" then
      return nil
    end
  end
  return normalized
end

local function safe_relative_repo_path(value)
  if not strings.is_path_safe_key(value, max_path_len) then
    return false
  end
  local text = tostring(value)
  if text:find(":", 1, true) ~= nil then
    return false
  end
  return true
end

local function cited_line_exists(root, relative_path, line_number)
  local path = tostring(root):gsub("/+$", "") .. "/" .. tostring(relative_path)
  local handle = io.open(path, "r")
  if handle == nil then
    return false
  end
  local current = 0
  for _line in handle:lines() do
    current = current + 1
    if current == line_number then
      handle:close()
      return true
    end
  end
  handle:close()
  return false
end

local function text_has_valid_repo_citation(root, text)
  for path, line in tostring(text or ""):gmatch("([%w%._%-%/]+):(%d+)") do
    local line_number = tonumber(line)
    if line_number ~= nil
      and line_number >= 1
      and line_number <= max_line_number
      and line_number == math.floor(line_number)
      and safe_relative_repo_path(path)
      and cited_line_exists(root, path, line_number) then
      return true
    end
  end
  return false
end

local function input_has_valid_repo_citation(root, input)
  if type(input) == "string" then
    return text_has_valid_repo_citation(root, input)
  end
  if type(input) ~= "table" then
    return false
  end
  if text_has_valid_repo_citation(root, input.stdout) then
    return true
  end
  for _, item in ipairs(input) do
    if input_has_valid_repo_citation(root, item) then
      return true
    end
  end
  return false
end

function J.repo_consulted_from_outputs(root, ...)
  if not is_safe_absolute_path(root) then
    return false
  end
  local inputs = { ... }
  for _, input in ipairs(inputs) do
    if input_has_valid_repo_citation(root, input) then
      return true
    end
  end
  return false
end

return J
