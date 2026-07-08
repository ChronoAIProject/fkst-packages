local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local content_filter = require("devloop.content_provenance")

local M = {}

local function append_csv_logins(logins, raw)
  for login in tostring(raw or ""):gmatch("[^,%s]+") do
    table.insert(logins, login)
  end
end

function M.from_logins(logins)
  return content_filter.author_policy_from_logins(logins or {})
end

function M.from_env(exec)
  local ok_bot, bot_login = pcall(devloop_base.read_env, "FKST_GITHUB_BOT_LOGIN", exec)
  bot_login = ok_bot and strings.trim(bot_login or "") or ""
  if bot_login == "" then
    error("devloop.github_author_policy: FKST_GITHUB_BOT_LOGIN is required for authored GitHub reads")
  end
  local logins = { bot_login }
  for _, name in ipairs({ "FKST_DEVLOOP_MANAGED_BOT_LOGINS", "FKST_GITHUB_AUTHORIZED_LOGINS" }) do
    local ok, raw = pcall(devloop_base.read_env, name, exec)
    if ok then
      append_csv_logins(logins, raw)
    end
  end
  return M.from_logins(logins)
end

return M
