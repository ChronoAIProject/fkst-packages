local exec_wrap = require("forge.github.exec")
local result = require("forge.github.result")
local content_filter = require("forge.github.content_filter")
local rate_limit = require("forge.github.rate_limit")

local M = {}

M.gh_result = result.gh_result

function M.new(exec, opts)
  assert(type(exec) == "function", "forge.github.new requires an exec function")
  local options = opts or {}
  local handle = {}
  local trusted_author_policy = options.trusted_author_policy
  if type(trusted_author_policy) == "function" then
    handle._trusted_author_policy = function()
      return trusted_author_policy(handle)
    end
  else
    handle._trusted_author_policy = trusted_author_policy
  end
  local rate_limiter = rate_limit.new({
    credential_scope = options.credential_scope,
    cache_get = options.cache_get,
    cache_set = options.cache_set,
    now = options.now,
  })
  function handle.is_authorized_author(login)
    return content_filter.is_authorized(login, content_filter.policy_whitelist(handle._trusted_author_policy))
  end
  function handle._exec(argv, timeout, context, stdout_policy)
    return exec_wrap.run(exec, argv, timeout, context, stdout_policy, handle._trusted_author_policy, rate_limiter)
  end
  require("forge.github.issue").install(handle)
  require("forge.github.entities").install(handle)
  require("forge.github.comments").install(handle)
  require("forge.github.graphql").install(handle)
  require("forge.github.workflows").install(handle)
  return handle
end

return M
