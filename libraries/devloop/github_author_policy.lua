local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local content_filter = require("forge.github.content_filter")

local M = {}

local function resolve_github_handle(github_handle)
  if type(github_handle) == "function" then
    local ok, resolved = pcall(github_handle)
    if ok then
      return resolved
    end
    return nil
  end
  return github_handle
end

-- Single source for the claim owner: normalize the configured bot login so all
-- downstream comparisons get the bare slug regardless of whether the deployment
-- configured "<slug>" or "<slug>[bot]". No-op for ordinary user logins.
function M.claim_owner()
  return devloop_base.strip_bot_login_suffix(devloop_base.assert_trusted_bot_configured() or devloop_base.trusted_bot_login())
end

function M.managed_bot_logins(exec)
  local raw = devloop_base.read_env("FKST_DEVLOOP_MANAGED_BOT_LOGINS", exec)
  local logins = {}
  for entry in tostring(raw or ""):gmatch("[^,%s]+") do
    local login = devloop_base.strip_bot_login_suffix(strings.trim(entry))
    if login ~= nil and login ~= "" then
      logins[login] = true
    end
  end
  return logins
end

function M.is_managed_bot_login(login, managed)
  local normalized = devloop_base.strip_bot_login_suffix(login)
  return normalized ~= nil and normalized ~= "" and type(managed) == "table" and managed[normalized] == true
end

function M.from_logins(logins)
  return content_filter.author_policy_from_logins(logins or {})
end

function M.from_env(exec, github_handle)
  local resolved_handle = resolve_github_handle(github_handle)
  local bot_login = nil
  if type(devloop_base.configured_trusted_bot_login) == "function" then
    bot_login = devloop_base.configured_trusted_bot_login()
  end
  if bot_login == nil or tostring(bot_login or "") == "" then
    local ok_bot = true
    ok_bot, bot_login = pcall(devloop_base.read_env, "FKST_GITHUB_BOT_LOGIN", exec)
    bot_login = ok_bot and strings.trim(bot_login or "") or ""
  end
  if bot_login == "" then
    error("devloop.github_author_policy: bot-login-missing: FKST_GITHUB_BOT_LOGIN is required for authored GitHub reads")
  end
  return content_filter.author_policy_from_options({
    owner = "devloop.github_author_policy",
    read_env = function(name)
      return devloop_base.read_env(name, exec)
    end,
    bot_login = bot_login,
    bot_login_env = "FKST_GITHUB_BOT_LOGIN",
    extra_login_envs = {
      "FKST_DEVLOOP_MANAGED_BOT_LOGINS",
      "FKST_GITHUB_AUTHORIZED_LOGINS",
    },
    github_handle = resolved_handle,
  })
end

function M.from_handle_policy(github_handle)
  local resolved_handle = resolve_github_handle(github_handle)
  if type(resolved_handle) == "table" and type(resolved_handle._trusted_author_policy) == "function" then
    return resolved_handle._trusted_author_policy()
  end
  return M.from_env(nil, resolved_handle)
end

function M.is_authorized(policy, login)
  return content_filter.is_authorized(login, content_filter.policy_whitelist(policy))
end

function M.for_exec(exec, github_handle)
  return M.from_env(exec, github_handle)
end

function M.github_options(exec)
  local policy = nil
  return {
    trusted_author_policy = function(github_handle)
      if policy == nil then
        policy = M.for_exec(exec, github_handle)
      end
      return policy
    end,
  }
end

return M
