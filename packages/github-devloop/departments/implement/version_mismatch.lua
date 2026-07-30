local transition_version = require("contract.transition_version")
local impl_failure = require("devloop.impl_failure")

local M = {}

local function decision(status, reason_code, cas_outcome)
  return {
    status = status,
    reason_code = reason_code,
    cas_outcome = cas_outcome,
  }
end

local function canonical_lineage(version)
  if type(version) ~= "string" then
    return nil
  end
  local parsed = transition_version.parse(version)
  local reimplement_seen = false
  for index, suffix in ipairs(parsed.suffixes or {}) do
    if suffix.kind == "reimplement" then
      if reimplement_seen
        or index ~= #parsed.suffixes
        or impl_failure.valid_attempt(suffix.n) == nil then
        return nil
      end
      reimplement_seen = true
    end
  end
  local lineage = transition_version.strip_suffixes(version)
  local inner = lineage:match("^ready/(.+)$")
  if inner == nil
    or inner:match("^ready/") ~= nil
    or lineage:find("/reimplement/", 1, true) ~= nil
    or lineage:find("-reimplement-", 1, true) ~= nil then
    return nil
  end
  return lineage
end

function M.is_canonical(version)
  return canonical_lineage(version) ~= nil
end

function M.classify(incoming_version, current_version)
  local incoming_lineage = canonical_lineage(incoming_version)
  local current_lineage = canonical_lineage(current_version)
  if incoming_lineage == nil or current_lineage == nil or incoming_lineage ~= current_lineage then
    return decision(
      "illegal",
      "incomparable-version-lineage",
      "fail-closed(incomparable-version-lineage)"
    )
  end

  local order = transition_version.compare(incoming_version, current_version)
  if order < 0 then
    return decision(
      "stale",
      "incoming-version-older",
      "skip-stale(incoming version < current marker version)"
    )
  end
  if order > 0 then
    return decision(
      "pending",
      "source-marker-not-visible",
      "retry-pending(from-state marker not yet visible)"
    )
  end
  return decision(
    "illegal",
    "incomparable-version-lineage",
    "fail-closed(incomparable-version-lineage)"
  )
end

return M
