local strings = require("contract.strings")

local M = {}

-- Organization-backed authorization is re-derived at least once per GitHub
-- observation interval, bounding the delay before a membership revocation is seen.
M.REVOCATION_BOUND_SECONDS = 5 * 60

local CACHE_RECORD_KIND = "forge.github.org-membership-authorization-cache.v1"

local function normalized_org(org)
  local value = strings.trim(org or ""):lower()
  if value == "" or value:find("/", 1, true) ~= nil then
    error("forge-github-authorization-cache: invalid-organization: organization must be a non-empty slug")
  end
  return value
end

function M.cache_key(org)
  return "forge/github/org-membership-authorization-v1/"
    .. strings.sanitize_key(normalized_org(org), 100):gsub("/", "-")
end

function M.epoch_at(now_seconds)
  local seconds = tonumber(now_seconds)
  if seconds == nil or seconds < 0 then
    error("forge-github-authorization-cache: invalid-current-time: current time must be non-negative seconds")
  end
  return math.floor(seconds / M.REVOCATION_BOUND_SECONDS)
end

local function current_epoch()
  return M.epoch_at(now())
end

local function available_outcome(logins)
  local copy = {}
  for _, login in ipairs(logins or {}) do
    copy[#copy + 1] = tostring(login)
  end
  return {
    tag = "available",
    logins = copy,
  }
end

local function unavailable_outcome(reason)
  return {
    tag = "unavailable",
    reason = tostring(reason or "unknown"),
  }
end

local function encode_string_array(values)
  local encoded = {}
  for _, value in ipairs(values or {}) do
    encoded[#encoded + 1] = strings.json_string(value)
  end
  return "[" .. table.concat(encoded, ",") .. "]"
end

local function encode_record(epoch, outcome)
  local encoded_outcome = nil
  if outcome.tag == "available" then
    encoded_outcome = '{"tag":"available","logins":' .. encode_string_array(outcome.logins) .. "}"
  else
    encoded_outcome = '{"tag":"unavailable","reason":' .. strings.json_string(outcome.reason) .. "}"
  end
  return '{"kind":' .. strings.json_string(CACHE_RECORD_KIND)
    .. ',"epoch":' .. tostring(epoch)
    .. ',"outcome":' .. encoded_outcome
    .. "}"
end

local function decode_string_array(values)
  if type(values) ~= "table" then
    return nil
  end
  local logins = {}
  for _, value in ipairs(values) do
    if type(value) ~= "string" then
      return nil
    end
    logins[#logins + 1] = value
  end
  return logins
end

local function decode_record(encoded, expected_epoch)
  local ok, record = pcall(json.decode, encoded or "")
  if not ok or type(record) ~= "table" or record.kind ~= CACHE_RECORD_KIND then
    return nil
  end
  if tonumber(record.epoch) ~= expected_epoch or type(record.outcome) ~= "table" then
    return nil
  end
  if record.outcome.tag == "available" then
    local logins = decode_string_array(record.outcome.logins)
    if logins ~= nil then
      return available_outcome(logins)
    end
    return nil
  end
  if record.outcome.tag == "unavailable" and type(record.outcome.reason) == "string" then
    return unavailable_outcome(record.outcome.reason)
  end
  return nil
end

local function settle(fetch_logins)
  local logins = fetch_logins()
  if type(logins) ~= "table" then
    return unavailable_outcome("fetch-unavailable")
  end
  return available_outcome(logins)
end

function M.get(org, fetch_logins)
  if type(fetch_logins) ~= "function" then
    error("forge-github-authorization-cache: invalid-fetch-logins: fetch_logins must be a function")
  end
  local key = M.cache_key(org)
  local epoch = current_epoch()
  local cached = decode_record(cache_get(key), epoch)
  if cached ~= nil then
    return cached
  end

  return with_lock(key, function()
    local locked_epoch = current_epoch()
    local locked_cached = decode_record(cache_get(key), locked_epoch)
    if locked_cached ~= nil then
      return locked_cached
    end
    local outcome = settle(fetch_logins)
    cache_set(key, encode_record(locked_epoch, outcome))
    return outcome
  end)
end

return M
