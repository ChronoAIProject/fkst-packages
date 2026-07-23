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

local function required_marker_attr(context, family, attr)
  local fact, failure = required(context, family)
  if failure ~= nil or type(fact) ~= "table" or fact[attr] == nil then
    return nil, MISSING_EVIDENCE
  end
  return fact[attr]
end

local marker_resolvers = {
  state = {
    version = function(context)
      return required_marker_attr(context, "state", "version")
    end,
  },
}

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

local source_ref_resolvers = {
  normalized = function(context)
    local source_ref, failure = required(context, "source_ref")
    if failure ~= nil then
      return nil, failure
    end
    return base_ids.normalize_source_ref(source_ref)
  end,
}

local function literal(value)
  return function()
    return value
  end
end

local literal_resolvers = {
  ["github-devloop.ready.v1"] = literal("github-devloop.ready.v1"),
  ["github-devloop.reviewing.v1"] = literal("github-devloop.reviewing.v1"),
  ["github-devloop.review-meta.v1"] = literal("github-devloop.review-meta.v1"),
  ["github-devloop.merge-ready.v1"] = literal("github-devloop.merge-ready.v1"),
  ["consensus.proposal.v1"] = literal("consensus.proposal.v1"),
}

local registries = {
  marker = marker_resolvers,
  source_ref = source_ref_resolvers,
  literal = literal_resolvers,
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
