-- std.saga: shared department shape for event-level idempotent sagas.
-- Contract: done(event) must be cheap, side-effect-free, and re-derived from
-- the durable fact source. It may cache immutable event decoding, but it must
-- never cache mutable durable facts for act(event).
--
-- act(event) must re-derive mutable durable facts inside its own fenced
-- critical section and re-check completion before each write-class effect.
-- At-least-once idempotency belongs at the write boundary, not at the earlier
-- done probe.
local S = {}
local strings = require("std.strings")

local function always_accept(_event)
  return true
end

local function validate_consumes(consumes)
  if type(consumes) ~= "table" or #consumes == 0 then
    error("std.saga: department requires non-empty consumes")
  end
end

local function validate_opts(opts)
  if type(opts) ~= "table" then
    error("std.saga: department requires opts")
  end
  validate_consumes(opts.consumes)
  if type(opts.done) ~= "function" then
    error("std.saga: department requires done")
  end
  if type(opts.act) ~= "function" then
    error("std.saga: department requires act")
  end
end

local function spec_from_opts(opts)
  return {
    consumes = opts.consumes,
    produces = opts.produces,
    stall_window = opts.stall_window,
    retry = opts.retry,
    fanout = opts.fanout,
    ephemeral = opts.ephemeral,
  }
end

local function event_identity(event)
  if type(event) ~= "table" then
    return nil
  end
  local payload = type(event.payload) == "table" and event.payload or {}
  local key = payload.dedup_key or event.dedup_key
  if key == nil then
    return nil
  end
  return tostring(event.queue or "queue") .. "/" .. tostring(key)
end

local function done_cache_key(name, event)
  local identity = event_identity(event)
  if identity == nil then
    return nil
  end
  local raw = tostring(name or "std.saga") .. "/" .. identity
  local checksum = strings.decimal_checksum(raw)
  local prefix = strings.sanitize_key(raw, 150):gsub("[/#]", "-"):gsub("%-+", "-")
  return "std/saga/done/" .. prefix .. "/" .. checksum
end

function S.done_once(name)
  return function(event)
    local key = done_cache_key(name, event)
    if key == nil then
      return false
    end
    return cache_get(key) ~= nil
  end
end

function S.act_once(name, act)
  if type(act) ~= "function" then
    error("std.saga: act_once requires act")
  end
  return function(event)
    local key = done_cache_key(name, event)
    if key ~= nil and cache_get(key) ~= nil then
      return nil
    end
    local result = act(event)
    if key ~= nil then
      cache_set(key, "done")
    end
    return result
  end
end

function S.act_once_when_done(name, act)
  if type(act) ~= "function" then
    error("std.saga: act_once_when_done requires act")
  end
  return function(event)
    local key = done_cache_key(name, event)
    if key ~= nil and cache_get(key) ~= nil then
      return nil
    end
    local result = act(event)
    if result == true and key ~= nil then
      cache_set(key, "done")
    end
    return result
  end
end

function S.department(opts)
  validate_opts(opts)

  local accept = opts.accept or always_accept
  local function raw(event)
    if not accept(event) then
      if type(opts.on_skip_foreign) == "function" then
        opts.on_skip_foreign(event)
      end
      return nil
    end
    if opts.done(event) then
      if type(opts.on_skip) == "function" then
        opts.on_skip(event)
      end
      return nil
    end
    return opts.act(event)
  end

  local name = opts.name or "std.saga"
  local wrapped = raw
  if type(opts.wrap) == "function" then
    wrapped = opts.wrap(name, raw)
  end
  _G.pipeline = wrapped

  return {
    spec = spec_from_opts(opts),
    pipeline = wrapped,
  }
end

return S
