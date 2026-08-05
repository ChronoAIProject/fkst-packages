local strings = require("contract.strings")
local github_view = require("forge.github_view")
local C = {}

local function assignee_login(assignee)
  if type(assignee) == "table" then
    if assignee.login ~= nil then
      return tostring(assignee.login)
    end
    if assignee.name ~= nil then
      return tostring(assignee.name)
    end
  elseif assignee ~= nil then
    return tostring(assignee)
  end
  return nil
end

local function issue_author_login(issue)
  if type(issue) ~= "table" then
    return nil
  end
  if issue.author_login ~= nil and tostring(issue.author_login) ~= "" then
    return tostring(issue.author_login)
  end
  if type(issue.author) == "table" and issue.author.login ~= nil and tostring(issue.author.login) ~= "" then
    return tostring(issue.author.login)
  end
  if type(issue.user) == "table" and issue.user.login ~= nil and tostring(issue.user.login) ~= "" then
    return tostring(issue.user.login)
  end
  return nil
end

function C.issue_author_login(issue)
  return issue_author_login(issue)
end

function C.assignee_logins(value)
  local logins = {}
  if type(value) ~= "table" then
    return logins
  end
  for _, assignee in ipairs(value) do
    local login = assignee_login(assignee)
    if login ~= nil and login ~= "" then
      table.insert(logins, login)
    end
  end
  return logins
end

function C.label_names(labels)
  return github_view.label_names(labels)
end

function C.each_paginated_item(decoded, callback)
  if type(decoded) ~= "table" then
    return
  end
  for _, value in ipairs(decoded) do
    if type(value) == "table" then
      if value[1] ~= nil then
        for _, item in ipairs(value) do
          callback(item)
        end
      elseif next(value) ~= nil then
        callback(value)
      end
    end
  end
end

function C.parse_numbered_list(stdout)
  local decoded = json.decode(stdout or "[]")
  local items = {}
  C.each_paginated_item(decoded, function(item)
    if type(item) == "table" and tonumber(item.number) ~= nil then
      table.insert(items, {
        number = tonumber(item.number),
        state = item.state,
        updated_at = item.updated_at or item.updatedAt,
      })
    end
  end)
  return items
end

C.strings = strings
C.github_view = github_view

return C
