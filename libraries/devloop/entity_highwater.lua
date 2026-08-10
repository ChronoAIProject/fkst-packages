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

local function highwater_context(args)
  local event = type(args.event) == "table" and args.event or {}
  local payload = type(event.payload) == "table" and event.payload or {}
  if args.enabled == false or event.queue ~= changed_queue then
    return nil
  end
  local key = H.key(args.consumer, payload.source_ref)
  local incoming = type(payload.updated_at) == "string" and payload.updated_at or nil
  local incoming_epoch = contract_time.iso_timestamp_epoch_seconds(incoming)
  local _, _, _, entity = parse_external_entity(payload.source_ref)
  if key == nil or incoming_epoch == nil then
    return nil
  end
  return {
    entity = entity,
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

local function read_highwater(args, context)
  local stored = context and cache_get(context.key) or nil
  local stored_epoch = contract_time.iso_timestamp_epoch_seconds(stored)
  if context ~= nil and stored_epoch ~= nil and context.incoming_epoch < stored_epoch then
    log_superseded(args, context, stored)
    return stored, stored_epoch, {
      outcome = "skip-superseded-version",
      skipped = true,
    }
  end
  return stored, stored_epoch, nil
end

local function run_work(args, context, prepared)
  local stored, stored_epoch, superseded = read_highwater(args, context)
  if superseded ~= nil then
    return superseded
  end

  local authoritative = nil
  local authoritative_epoch = nil
  local function record_authoritative_version(value)
    local epoch = contract_time.iso_timestamp_epoch_seconds(value)
    if epoch ~= nil and (authoritative_epoch == nil or epoch > authoritative_epoch) then
      authoritative = value
      authoritative_epoch = epoch
    end
  end

  local result = args.work(prepared, record_authoritative_version)
  local reconciled, reconciled_epoch = stored, stored_epoch
  if context ~= nil and authoritative_epoch ~= nil then
    -- Work always re-reads the external entity before producing effects. The only
    -- shared mutable state owned here is this consumer-local high-water value, so
    -- lock only its monotonic read-modify-write instead of the source reconciliation.
    with_lock(context.key, function()
      local latest = cache_get(context.key)
      local latest_epoch = contract_time.iso_timestamp_epoch_seconds(latest)
      if latest_epoch == nil or authoritative_epoch > latest_epoch then
        cache_set(context.key, authoritative)
        reconciled, reconciled_epoch = authoritative, authoritative_epoch
      else
        reconciled, reconciled_epoch = latest, latest_epoch
      end
    end)
  end
  return {
    outcome = "reconciled",
    reconciled_updated_at = context ~= nil and reconciled_epoch ~= nil and reconciled or nil,
    result = result,
    skipped = false,
  }
end

function H.reconcile(args)
  if type(args) ~= "table" or type(args.work) ~= "function" then
    error("devloop: reconcile-work-missing: devloop.entity_highwater: reconcile requires args.work")
  end
  local context = highwater_context(args)
  local _, _, superseded = read_highwater(args, context)
  if superseded ~= nil then
    return superseded
  end
  local prepared = nil
  if type(args.prepare) == "function" then
    prepared = args.prepare()
  end
  return run_work(args, context, prepared)
end

return H
