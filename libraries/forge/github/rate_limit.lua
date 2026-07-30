local M = {}

local function command_resource(argv)
  if type(argv) ~= "table" or argv[1] ~= "gh" then
    return nil
  end
  if argv[2] == "api" then
    return argv[3] == "graphql" and "graphql" or "core"
  end
  if (argv[2] == "issue" or argv[2] == "pr") and argv[3] == "view" then
    return "graphql"
  end
  return nil
end

local function resolve(value)
  if type(value) == "function" then
    return value()
  end
  return value
end

local function rate_limit_error(scope, resource, reset_at, context)
  local message = "forge.github: " .. tostring(context or "GitHub command")
    .. " blocked: gh-rate-limited: credential " .. scope
    .. " has exhausted " .. resource .. " until " .. tostring(reset_at)
  return setmetatable({
    class = "gh-rate-limited",
    retryable = true,
    credential_scope = scope,
    resource = resource,
    reset_at = reset_at,
    context = context,
    message = message,
  }, {
    __tostring = function(err)
      return err.message
    end,
  })
end

function M.new(opts)
  local options = opts or {}
  local read_cache = options.cache_get or cache_get
  local write_cache = options.cache_set or cache_set
  local read_now = options.now or now

  local function credential_scope()
    local raw_scope = resolve(options.credential_scope)
    local scope = tostring(raw_scope or ""):lower():gsub("%[bot%]$", "")
    if scope == "" then
      return nil
    end
    if scope:match("^[%w][%w%-]*$") == nil then
      error("forge.github.rate_limit: credential_scope must be a GitHub login")
    end
    return scope
  end

  local function current_time()
    if type(read_now) ~= "function" then
      return nil
    end
    return tonumber(read_now())
  end

  local function cache_key(scope, resource)
    return "forge/github/rate-limit/" .. scope .. "/" .. resource
  end

  local limiter = {}

  function limiter.before(argv, context)
    local resource = command_resource(argv)
    if resource == nil then
      return
    end
    local scope = credential_scope()
    local current = current_time()
    if resource == nil or scope == nil or current == nil
      or type(read_cache) ~= "function" or type(write_cache) ~= "function" then
      return
    end
    local key = cache_key(scope, resource)
    local reset_at = tonumber(read_cache(key) or "")
    if reset_at ~= nil and reset_at > current then
      error(rate_limit_error(scope, resource, reset_at, context))
    end
    if reset_at ~= nil then
      write_cache(key, "")
    end
  end

  function limiter.observe_failure(exec, argv, timeout)
    local resource = command_resource(argv)
    if resource == nil then
      return nil
    end
    local scope = credential_scope()
    local current = current_time()
    if resource == nil or scope == nil or current == nil
      or type(read_cache) ~= "function" or type(write_cache) ~= "function"
      or json == nil or type(json.decode) ~= "function" then
      return nil
    end

    local ok_probe, probe = pcall(exec, {
      argv = { "gh", "api", "rate_limit" },
      timeout = timeout,
    })
    if not ok_probe or type(probe) ~= "table" or tonumber(probe.exit_code) ~= 0 then
      return nil
    end
    local ok_decode, decoded = pcall(json.decode, probe.stdout or "")
    local fact = ok_decode and type(decoded) == "table"
      and type(decoded.resources) == "table" and decoded.resources[resource] or nil
    local remaining = type(fact) == "table" and tonumber(fact.remaining) or nil
    local reset_at = type(fact) == "table" and tonumber(fact.reset) or nil
    if remaining ~= 0 or reset_at == nil or reset_at <= current then
      return nil
    end
    write_cache(cache_key(scope, resource), tostring(reset_at))
    return {
      credential_scope = scope,
      resource = resource,
      reset_at = reset_at,
    }
  end

  return limiter
end

M.command_resource = command_resource

return M
