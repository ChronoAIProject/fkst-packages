local S = {}

function S.install(M)
local known_issue_types = {
  Bug = true,
  Feature = true,
  Task = true,
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.normalize_issue_type(value)
  local text = trim(value)
  if known_issue_types[text] then
    return text
  end
  return nil
end

function M.issue_type_from_json(value)
  if type(value) == "table" then
    return M.normalize_issue_type(value.name or value.Name or value.type or value.Type)
  end
  return M.normalize_issue_type(value)
end

function M.issue_type_patch_cmd(repo, issue_number, issue_type)
  local selected_type = M.normalize_issue_type(issue_type)
  if selected_type == nil then
    error("github-devloop: invalid issue type")
  end
  return "gh api --method PATCH "
    .. M._shell_single_quote("repos/" .. tostring(repo) .. "/issues/" .. tostring(issue_number))
    .. " -f " .. M._shell_single_quote("type=" .. selected_type)
end

function M.classify_issue_type(current)
  local title = tostring(current and current.title or ""):lower()
  local body = tostring(current and current.body or ""):lower()
  local text = title .. "\n" .. body
  if text:find("bug", 1, true)
    or text:find("broken", 1, true)
    or text:find("crash", 1, true)
    or text:find("fail", 1, true)
    or text:find("failure", 1, true)
    or text:find("error", 1, true)
    or text:find("regression", 1, true)
    or text:find("misbehavior", 1, true) then
    return "Bug"
  end
  if text:find("feature", 1, true)
    or text:find("capability", 1, true)
    or text:find("contract", 1, true)
    or text:find("protocol", 1, true)
    or text:find("support ", 1, true)
    or text:find("add ", 1, true)
    or text:find("new ", 1, true) then
    return "Feature"
  end
  return "Task"
end
end

return S
