local base_ids = require("devloop.base_ids")

local R = {}

local MISSING_EVIDENCE = "missing-evidence"

local known_prefixes = {
  marker = true,
  source_ref = true,
  literal = true,
  dedup = true,
  comment_body = true,
  typed = true,
}

local function required(context, name)
  if type(context) ~= "table" or context[name] == nil then
    return nil, MISSING_EVIDENCE
  end
  return context[name]
end

local dedup_resolvers = {
  ready = function(context)
    local dedup_key, failure = required(context, "dedup_key")
    if failure ~= nil then
      return nil, failure
    end
    return base_ids.dedup_key({
      "ready",
      tostring(dedup_key),
    })
  end,

  reviewing = function(context)
    local proposal_id, failure = required(context, "proposal_id")
    if failure ~= nil then
      return nil, failure
    end
    local version
    version, failure = required(context, "version")
    if failure ~= nil then
      return nil, failure
    end
    local pr_number
    pr_number, failure = required(context, "pr_number")
    if failure ~= nil then
      return nil, failure
    end
    return base_ids.dedup_key({
      "reviewing",
      tostring(proposal_id),
      tostring(version),
      tostring(pr_number),
    })
  end,
}

local registries = {
  dedup = dedup_resolvers,
}

local function fail(message)
  error("devloop: invalid payload token: " .. message, 0)
end

local function parsed_token(token)
  if type(token) ~= "string" then
    fail("token must be a string")
  end
  local prefix, name = token:match("^([a-z_]+):([^:]+)$")
  if prefix == nil then
    fail("malformed token " .. tostring(token))
  end
  if known_prefixes[prefix] ~= true then
    fail("unknown prefix " .. prefix)
  end

  if prefix == "marker" then
    local family, attr = name:match("^([^%.]+)%.([^%.]+)$")
    if family == nil then
      fail("malformed marker token " .. token)
    end
    local families = registries.marker or {}
    if families[family] == nil then
      fail("unknown marker family " .. family)
    end
    if families[family][attr] == nil then
      fail("unknown marker attr " .. family .. "." .. attr)
    end
    return families[family][attr]
  end

  local resolver = (registries[prefix] or {})[name]
  if resolver == nil then
    if prefix == "source_ref" then
      fail("unknown source_ref derivation " .. name)
    elseif prefix == "literal" then
      fail("unknown literal value " .. name)
    else
      fail("unknown " .. prefix .. " strategy " .. name)
    end
  end
  return resolver
end

function R.validate(token)
  parsed_token(token)
  return true
end

function R.resolve(token, context)
  return parsed_token(token)(context)
end

return R
