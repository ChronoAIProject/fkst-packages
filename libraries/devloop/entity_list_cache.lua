local base_ids = require("devloop.base_ids")
local strings = require("contract.strings")
local github_view = require("forge.github_view")

local C = {}
local json_string = github_view.json_string

local function normalize_poll_key(value)
  local text = tostring(value or "")
  if text ~= "" then
    return "poll-" .. strings.sanitize_key(text, 120):gsub("/", "-")
  end
  return nil
end

local function list_cache_key(repo, kind, scope, poll_key)
  local selected_kind = tostring(kind or "")
  if selected_kind ~= "issue" and selected_kind ~= "pr" then
    error("github-devloop: invalid entity list kind")
  end
  local normalized_poll_key = normalize_poll_key(poll_key)
  if normalized_poll_key == nil then
    return nil
  end
  return table.concat({
    "github-devloop",
    "entity-list-v2",
    base_ids.safe_repo(repo),
    selected_kind,
    strings.sanitize_key(scope or "open", 80):gsub("/", "-"),
    normalized_poll_key,
  }, "/")
end

local function decode_cached_list(encoded)
  local ok, decoded = pcall(json.decode, encoded or "")
  if not ok or type(decoded) ~= "table" or decoded.stdout == nil then
    return nil
  end
  return {
    stdout = tostring(decoded.stdout),
    stderr = "",
    exit_code = 0,
  }
end

local function encode_cached_list(stdout)
  return '{"stdout":' .. json_string(stdout or "") .. "}"
end

local function available_outcome(stdout)
  return {
    tag = "available",
    stdout = tostring(stdout or ""),
  }
end

local function unavailable_outcome(reason)
  return {
    tag = "unavailable",
    reason = tostring(reason or "unknown"),
  }
end

local function decode_settled_outcome(encoded)
  local ok, decoded = pcall(json.decode, encoded or "")
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  if decoded.tag == "available" and type(decoded.stdout) == "string" then
    return available_outcome(decoded.stdout)
  end
  if decoded.tag == "unavailable" and type(decoded.reason) == "string" then
    return unavailable_outcome(decoded.reason)
  end
  return nil
end

local function encode_settled_outcome(outcome)
  if outcome.tag == "available" then
    return '{"tag":"available","stdout":' .. json_string(outcome.stdout) .. "}"
  end
  return '{"tag":"unavailable","reason":' .. json_string(outcome.reason) .. "}"
end

local function fetch_shared_list(repo, kind, scope, poll_key, exec_spec)
  local key = list_cache_key(repo, kind, scope, poll_key)
  if key == nil then
    return exec_spec()
  end
  local cached = decode_cached_list(cache_get(key))
  if cached ~= nil then
    return cached
  end

  return with_lock(key, function()
    local locked_cached = decode_cached_list(cache_get(key))
    if locked_cached ~= nil then
      return locked_cached
    end
    local result = exec_spec()
    if type(result) == "table" and result.exit_code == 0 then
      cache_set(key, encode_cached_list(result.stdout or ""))
    end
    return result
  end)
end

local function execute_settled(exec_spec, validate_spec)
  local ok_result, result = pcall(exec_spec)
  if not ok_result then
    return unavailable_outcome("fetch-threw")
  end
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return unavailable_outcome("fetch-nonzero")
  end
  local ok_validation, valid, reason = pcall(validate_spec, result)
  if not ok_validation then
    return unavailable_outcome("validation-threw")
  end
  if valid ~= true then
    return unavailable_outcome(reason or "validation-failed")
  end
  return available_outcome(result.stdout)
end

local function fetch_shared_settled_list(repo, kind, scope, poll_key, exec_spec, validate_spec)
  local key = list_cache_key(repo, kind, scope, poll_key)
  if key == nil then
    return execute_settled(exec_spec, validate_spec)
  end
  local cached = decode_settled_outcome(cache_get(key))
  if cached ~= nil then
    return cached
  end

  return with_lock(key, function()
    local locked_cached = decode_settled_outcome(cache_get(key))
    if locked_cached ~= nil then
      return locked_cached
    end
    local outcome = execute_settled(exec_spec, validate_spec)
    cache_set(key, encode_settled_outcome(outcome))
    return outcome
  end)
end

local function poll_epoch_cache_key(repo)
  return table.concat({
    "github-proxy",
    "poll-epoch-v1",
    base_ids.safe_repo(repo),
  }, "/")
end

local function compare_poll_timestamp(candidate, current)
  local candidate_number = tonumber(candidate)
  local current_number = tonumber(current)
  if candidate_number ~= nil and current_number ~= nil then
    if candidate_number == current_number then
      return 0
    end
    return candidate_number > current_number and 1 or -1
  end
  if tostring(candidate) == tostring(current) then
    return 0
  end
  return tostring(candidate) > tostring(current) and 1 or -1
end

local function poll_execution_epoch(timestamp, sub_epoch)
  return tostring(timestamp) .. "/sub-epoch/" .. tostring(sub_epoch)
end

local function decode_poll_epoch_state(encoded)
  local ok, state = pcall(json.decode, encoded or "")
  if not ok or type(state) ~= "table" or type(state.timestamp) ~= "string" then
    return nil
  end
  local sub_epoch = tonumber(state.sub_epoch)
  if state.timestamp == "" or sub_epoch == nil or sub_epoch < 0 or sub_epoch % 1 ~= 0 then
    return nil
  end
  return {
    timestamp = state.timestamp,
    sub_epoch = sub_epoch,
    epoch = poll_execution_epoch(state.timestamp, sub_epoch),
  }
end

local function encode_poll_epoch_state(timestamp, sub_epoch)
  return '{"timestamp":' .. json_string(timestamp)
    .. ',"sub_epoch":' .. tostring(sub_epoch)
    .. "}"
end

local function current_poll_epoch_state(repo)
  local encoded = tostring(cache_get(poll_epoch_cache_key(repo)) or "")
  if encoded == "" then
    return nil
  end
  local state = decode_poll_epoch_state(encoded)
  if state == nil then
    error("github-devloop: cached poll epoch state is malformed")
  end
  return state
end

function C.entity_list_cache_key(repo, kind, scope, poll_key)
  return list_cache_key(repo, kind, scope, poll_key)
end

function C.fetch_shared_settled_list(repo, kind, scope, poll_key, exec_spec, validate_spec)
  if type(exec_spec) ~= "function" or type(validate_spec) ~= "function" then
    error("github-devloop: settled entity list fetch requires exec and validation functions")
  end
  return fetch_shared_settled_list(repo, kind, scope, poll_key, exec_spec, validate_spec)
end

function C.poll_epoch_cache_key(repo)
  return poll_epoch_cache_key(repo)
end

function C.record_poll_epoch(repo, poll_key)
  local timestamp = tostring(poll_key or "")
  if timestamp == "" then
    error("github-devloop: poll epoch must be non-empty")
  end
  local key = poll_epoch_cache_key(repo)
  local recorded = false
  local current_epoch = nil
  with_lock(key, function()
    local current = current_poll_epoch_state(repo)
    local comparison = current == nil and 1 or compare_poll_timestamp(timestamp, current.timestamp)
    if comparison < 0 then
      current_epoch = current.epoch
      return
    end
    local sub_epoch = comparison == 0 and current.sub_epoch + 1 or 0
    current_epoch = poll_execution_epoch(timestamp, sub_epoch)
    cache_set(key, encode_poll_epoch_state(timestamp, sub_epoch))
    recorded = true
  end)
  return recorded, current_epoch
end

function C.poll_epoch_is_current(repo, poll_key)
  if poll_key == nil or tostring(poll_key) == "" then
    return true
  end
  local current = current_poll_epoch_state(repo)
  return current ~= nil and current.epoch == tostring(poll_key)
end

function C.with_current_poll_epoch(repo, poll_key, fn)
  if type(fn) ~= "function" then
    error("github-devloop: poll epoch guard requires a function")
  end
  if poll_key == nil or tostring(poll_key) == "" then
    return true, fn()
  end
  return with_lock(poll_epoch_cache_key(repo), function()
    if not C.poll_epoch_is_current(repo, poll_key) then
      return false, nil
    end
    return true, fn()
  end)
end

function C.entity_list_poll_key(event)
  if type(event) == "table" then
    local payload = event.payload
    if type(payload) == "table" then
      if payload.poll_token ~= nil then
        return tostring(payload.poll_token)
      end
    end
    if event.ts ~= nil then
      return tostring(event.ts)
    end
    if type(payload) == "table" then
      for _, key in ipairs({ "tick", "generated_at", "ts" }) do
        if payload[key] ~= nil then
          return tostring(payload[key])
        end
      end
    end
  end
  return nil
end

function C.entity_list_poll_epoch(event)
  local payload = type(event) == "table" and event.payload or nil
  if type(payload) == "table" and payload.poll_token ~= nil and tostring(payload.poll_token) ~= "" then
    return tostring(payload.poll_token)
  end
  return nil
end

function C.fetch_shared_issue_observe_list(M, repo, opts)
  local options = opts or {}
  local exec_opts = M.gh_issue_list_observe_opts(repo)
  exec_opts.timeout = options.timeout or exec_opts.timeout
  return fetch_shared_list(repo, "issue", "open", options.poll_key, function()
    return exec_opts.run(exec_opts.timeout)
  end)
end

function C.fetch_shared_pr_observe_list(M, repo, opts)
  local options = opts or {}
  local exec_opts = M.gh_pr_list_observe_opts(repo)
  exec_opts.timeout = options.timeout or exec_opts.timeout
  return fetch_shared_list(repo, "pr", "open", options.poll_key, function()
    return exec_opts.run(exec_opts.timeout)
  end)
end

return C
