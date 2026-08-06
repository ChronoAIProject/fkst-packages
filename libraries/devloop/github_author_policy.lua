local devloop_base = require("devloop.base")
local strings = require("contract.strings")
local content_filter = require("forge.github.content_filter")

local policy = {}

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
function policy.claim_owner()
  return devloop_base.strip_bot_login_suffix(devloop_base.assert_trusted_bot_configured() or devloop_base.trusted_bot_login())
end

function policy.managed_bot_logins(exec)
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

function policy.is_managed_bot_login(login, managed)
  local normalized = devloop_base.strip_bot_login_suffix(login)
  return normalized ~= nil and normalized ~= "" and type(managed) == "table" and managed[normalized] == true
end

function policy.is_trusted_issue_author_login(login, managed)
  if policy.is_managed_bot_login(login, managed) then
    return true
  end
  local trusted = devloop_base.trusted_bot_login()
  return trusted ~= nil
    and trusted ~= ""
    and devloop_base.strip_bot_login_suffix(login) == tostring(trusted)
end

function policy.from_logins(logins)
  return content_filter.author_policy_from_logins(logins or {})
end

function policy.from_env(exec, github_handle)
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

function policy.from_handle_policy(github_handle)
  local resolved_handle = resolve_github_handle(github_handle)
  if type(resolved_handle) == "table" and type(resolved_handle._trusted_author_policy) == "function" then
    return resolved_handle._trusted_author_policy()
  end
  return policy.from_env(nil, resolved_handle)
end

function policy.is_authorized(author_policy, login)
  return content_filter.is_authorized(login, content_filter.policy_whitelist(author_policy))
end

function policy.for_exec(exec, github_handle)
  return policy.from_env(exec, github_handle)
end

function policy.github_options(exec)
  local author_policy = nil
  return {
    trusted_author_policy = function(github_handle)
      if author_policy == nil then
        author_policy = policy.for_exec(exec, github_handle)
      end
      return author_policy
    end,
  }
end

return policy
