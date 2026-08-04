local base_ids = require("devloop.base_ids")
local contract_time = require("contract.time")
local devloop_logging = require("devloop.logging")
local strings = require("contract.strings")

local H = {}
local changed_queue = "github-proxy.github_entity_changed"

local function parse_external_entity(source_ref)
  if type(source_ref) ~= "table" or source_ref.kind ~= "external" then
    return nil
  end
  local ref = tostring(source_ref.ref or "")
  local repo, kind, number = ref:match("^(.-)#(issue)/(%d+)$")
  if repo == nil then
    repo, kind, number = ref:match("^(.-)#(pr)/(%d+)$")
  end
  if repo == nil or repo == ""
    or base_ids.safe_repo(repo) ~= repo
    or base_ids.safe_issue(number) ~= tostring(number) then
    return nil
  end
  return repo, kind, number, ref
end

local function safe_consumer(consumer)
  local value = tostring(consumer or "")
  if value == "" or not strings.is_path_safe_key(value, base_ids.max_key_len) then
    return nil
  end
  return value
end

function H.key(consumer, source_ref)
  local selected_consumer = safe_consumer(consumer)
  local repo, kind, number = parse_external_entity(source_ref)
  if selected_consumer == nil or repo == nil then
    return nil
  end
  return selected_consumer .. "/highwater/" .. repo .. "/" .. kind .. "/" .. number
end

local function lock_hint_key(consumer, source_ref)
  local selected_consumer = safe_consumer(consumer)
  local repo, kind, number = parse_external_entity(source_ref)
  if selected_consumer == nil or repo == nil then
    return nil
  end
  return selected_consumer .. "/highwater-lock/" .. repo .. "/" .. kind .. "/" .. number
end

local function valid_lock_key(value)
  return type(value) == "string"
    and value ~= ""
    and strings.is_path_safe_key(value, base_ids.max_dedup_len)
end

local function highwater_context(args)
  local event = type(args.event) == "table" and args.event or {}
  local payload = type(event.payload) == "table" and event.payload or {}
  if args.enabled == false or event.queue ~= changed_queue then
    return nil
  end
  local key = H.key(args.consumer, payload.source_ref)
  local hint_key = lock_hint_key(args.consumer, payload.source_ref)
  local incoming = type(payload.updated_at) == "string" and payload.updated_at or nil
  local incoming_epoch = contract_time.iso_timestamp_epoch_seconds(incoming)
  local _, _, _, entity = parse_external_entity(payload.source_ref)
  if key == nil or hint_key == nil or incoming_epoch == nil then
    return nil
  end
  return {
    entity = entity,
    hint_key = hint_key,
    incoming = incoming,
    incoming_epoch = incoming_epoch,
    key = key,
  }
end

local function log_superseded(args, context, stored)
  local department = tostring(args.consumer or "unknown"):match("([^/]+)$") or "unknown"
  devloop_logging.log_line("info", department, "unknown", "RECONCILE", {
    "outcome=skip-superseded-version",
    "consumer=" .. tostring(args.consumer),
    "entity=" .. tostring(context.entity),
    "incoming_updated_at=" .. tostring(context.incoming),
    "stored_updated_at=" .. tostring(stored),
  })
end

local function run_work(args, context, lock_key, prepared)
  local stored = context and cache_get(context.key) or nil
  local stored_epoch = contract_time.iso_timestamp_epoch_seconds(stored)
  if context ~= nil and stored_epoch ~= nil and context.incoming_epoch < stored_epoch then
    log_superseded(args, context, stored)
    return {
      outcome = "skip-superseded-version",
      skipped = true,
    }
  end

  if prepared == nil and type(args.resolve_lock) == "function" then
    local resolved_lock, resolved_prepared = args.resolve_lock()
    prepared = resolved_prepared
    if resolved_lock ~= lock_key then
      return {
        __entity_highwater_reroute = true,
        lock_key = resolved_lock,
        prepared = prepared,
      }
    end
  end

  local result = args.work(prepared)
  if context ~= nil and valid_lock_key(lock_key) then
    cache_set(context.key, context.incoming)
    cache_set(context.hint_key, lock_key)
  end
  return {
    outcome = "reconciled",
    result = result,
    skipped = false,
  }
end

local function under_lock(args, context, lock_key, prepared)
  if args.lock_held == true then
    return run_work(args, context, lock_key, prepared)
  end
  return with_lock(lock_key, function()
    return run_work(args, context, lock_key, prepared)
  end)
end

function H.reconcile(args)
  if type(args) ~= "table" or type(args.work) ~= "function" then
    error("devloop.entity_highwater: reconcile requires args.work")
  end
  local context = highwater_context(args)
  local lock_key = args.lock_key
  if not valid_lock_key(lock_key) and context ~= nil then
    local hinted = cache_get(context.hint_key)
    if valid_lock_key(hinted) then
      lock_key = hinted
    end
  end

  local prepared = nil
  if not valid_lock_key(lock_key) and type(args.resolve_lock) == "function" then
    lock_key, prepared = args.resolve_lock()
  end
  if not valid_lock_key(lock_key) then
    return {
      outcome = "reconciled",
      result = args.work(prepared),
      skipped = false,
    }
  end

  local result = under_lock(args, context, lock_key, prepared)
  if type(result) == "table" and result.__entity_highwater_reroute == true then
    if not valid_lock_key(result.lock_key) then
      return {
        outcome = "reconciled",
        result = args.work(result.prepared),
        skipped = false,
      }
    end
    return under_lock(args, context, result.lock_key, result.prepared)
  end
  return result
end

return H
