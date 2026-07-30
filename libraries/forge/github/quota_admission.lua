local M = {}

-- GitHub's primary GraphQL quota is an hourly fixed window whose reset is
-- reported as an authoritative epoch second by the rate_limit endpoint.
local primary_window_seconds = 60 * 60

local function command_resource(argv)
  if type(argv) ~= "table" or argv[1] ~= "gh" then
    return nil
  end
  if argv[2] == "api" then
    return argv[3] == "graphql" and "graphql" or nil
  end
  if argv[2] == "issue" and argv[3] == "view" then
    return "graphql"
  end
  if argv[2] == "pr" and argv[3] == "view" then
    return "graphql"
  end
  return nil
end

local function finite_number(value)
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or number == -math.huge then
    return nil
  end
  return number
end

local function normalized_fact(fact)
  if type(fact) ~= "table" then
    return nil, "provider fact is not an object"
  end
  local limit = finite_number(fact.limit)
  local remaining = finite_number(fact.remaining)
  local reset_at = finite_number(fact.reset_at or fact.reset)
  if limit == nil or limit <= 0 or limit ~= math.floor(limit) then
    return nil, "provider limit is not a positive integer"
  end
  if remaining == nil or remaining < 0 or remaining > limit or remaining ~= math.floor(remaining) then
    return nil, "provider remaining is outside the declared limit"
  end
  if reset_at == nil or reset_at <= 0 or reset_at ~= math.floor(reset_at) then
    return nil, "provider reset is not a positive epoch second"
  end
  return {
    limit = limit,
    remaining = remaining,
    reset_at = reset_at,
  }
end

function M.decision(raw_fact, now_seconds)
  local fact, invalid_reason = normalized_fact(raw_fact)
  local current = finite_number(now_seconds)
  if fact == nil then
    return nil, invalid_reason
  end
  if current == nil or current < 0 then
    return nil, "host clock is not a non-negative epoch second"
  end

  local window_started_at = fact.reset_at - primary_window_seconds
  if current < window_started_at or current >= fact.reset_at then
    return nil, "provider reset does not describe the current hourly window"
  end

  local spent = fact.limit - fact.remaining
  local retry_at = window_started_at + math.ceil(spent * primary_window_seconds / fact.limit)
  return {
    kind = retry_at > current and "defer" or "admit",
    retry_at = retry_at,
    reset_at = fact.reset_at,
    limit = fact.limit,
    remaining = fact.remaining,
  }
end

local function quota_error(class, context, resource, message, fields)
  local err = fields or {}
  err.class = class
  err.retryable = true
  err.permanent = false
  err.context = context
  err.resource = resource
  err.message = "forge.github: " .. tostring(context or "GitHub command") .. ": " .. message
  return setmetatable(err, {
    __tostring = function(value)
      return value.message
    end,
  })
end

local function read_provider_fact(exec, resource, timeout, context)
  local ok_probe, probe = pcall(exec, {
    argv = { "gh", "api", "rate_limit", "--jq", ".resources." .. resource },
    timeout = timeout,
  })
  if not ok_probe or type(probe) ~= "table" or tonumber(probe.exit_code) ~= 0 then
    error(quota_error(
      "gh-quota-facts-unavailable",
      context,
      resource,
      "authoritative quota facts are unavailable",
      { result = type(probe) == "table" and probe or nil }
    ))
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    error(quota_error(
      "gh-quota-facts-invalid",
      context,
      resource,
      "authoritative quota facts cannot be decoded"
    ))
  end
  local ok_decode, decoded = pcall(json.decode, probe.stdout or "")
  if not ok_decode or type(decoded) ~= "table" then
    error(quota_error(
      "gh-quota-facts-invalid",
      context,
      resource,
      "authoritative quota facts are malformed",
      { result = probe }
    ))
  end
  return decoded
end

local function deferred_error(context, resource, verdict)
  return quota_error(
    "gh-rate-limited",
    context,
    resource,
    "provider quota admission deferred until " .. tostring(verdict.retry_at),
    {
      quota_deferred = true,
      retry_at = verdict.retry_at,
      reset_at = verdict.reset_at,
      limit = verdict.limit,
      remaining = verdict.remaining,
    }
  )
end

function M.new(opts)
  local options = opts or {}
  local enabled = options.enabled == true
  local read_now = options.now or now
  local limiter = {}

  function limiter.before(exec, argv, timeout, context)
    local resource = command_resource(argv)
    if not enabled or resource == nil then
      return
    end
    if type(read_now) ~= "function" then
      error(quota_error(
        "gh-quota-facts-unavailable",
        context,
        resource,
        "host clock is unavailable"
      ))
    end
    local fact = read_provider_fact(exec, resource, timeout, context)
    local verdict, invalid_reason = M.decision(fact, read_now())
    if verdict == nil then
      error(quota_error(
        "gh-quota-facts-invalid",
        context,
        resource,
        "authoritative quota facts are invalid: " .. tostring(invalid_reason)
      ))
    end
    if verdict.kind == "defer" then
      error(deferred_error(context, resource, verdict))
    end
  end

  return limiter
end

M.command_resource = command_resource

return M
