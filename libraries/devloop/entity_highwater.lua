local base_ids = require("devloop.base_ids")
local contract_time = require("contract.time")
local devloop_logging = require("devloop.logging")
local strings = require("contract.strings")

local H = {}
local changed_queue = "github-proxy.github_entity_changed"

local function valid_commit_currency(value)
  return type(value) == "table"
    and type(value.order) == "string"
    and value.order ~= ""
    and value.order:find("\n", 1, true) == nil
    and type(value.token) == "string"
    and value.token:find("\n", 1, true) == nil
end

function H.commit_currency(order, token)
  local value = { order = tostring(order or ""), token = tostring(token or "") }
  if not valid_commit_currency(value) then
    error("devloop: optimistic-commit-currency-invalid: order and token must be single-line strings")
  end
  return value
end

local function same_commit_currency(left, right)
  return valid_commit_currency(left)
    and valid_commit_currency(right)
    and left.order == right.order
    and left.token == right.token
end

function H.commit_cache_key(lock_key, owner)
  return base_ids.dedup_key({ tostring(lock_key), "optimistic-commit", tostring(owner) })
end

function H.commit_cache_load(key)
  local raw = cache_get(key)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local split = raw:find("\n", 1, true)
  if split == nil then
    error("devloop: optimistic-commit-cache-invalid: committed currency is malformed")
  end
  return H.commit_currency(raw:sub(1, split - 1), raw:sub(split + 1))
end

function H.commit_cache_store(key, currency)
  if not valid_commit_currency(currency) then
    error("devloop: optimistic-commit-currency-invalid: committed currency is malformed")
  end
  cache_set(key, currency.order .. "\n" .. currency.token)
end

local function committed_after_plan(committed, planned)
  if committed == nil then
    return false
  end
  if committed.order ~= planned.order then
    return committed.order > planned.order
  end
  return committed.token ~= planned.token
end

function H.commit(args)
  if type(args) ~= "table"
    or type(args.refresh) ~= "function"
    or type(args.publish) ~= "function"
    or type(args.load) ~= "function"
    or type(args.store) ~= "function"
    or type(args.lock_key) ~= "string"
    or args.lock_key == ""
    or not valid_commit_currency(args.planned)
    or not valid_commit_currency(args.committed) then
    error("devloop: optimistic-commit-arguments-invalid: complete commit arguments are required")
  end
  if args.committed.order < args.planned.order then
    error("devloop: optimistic-commit-regression: committed currency cannot precede planned currency")
  end

  local fresh = args.refresh()
  if not same_commit_currency(args.planned, fresh) then
    return false, "source-currency-changed"
  end

  return with_lock(args.lock_key, function()
    local latest = args.load()
    if committed_after_plan(latest, args.planned) then
      return false, "source-currency-changed"
    end
    args.publish()
    if latest == nil or latest.order < args.committed.order
      or (latest.order == args.committed.order and latest.token == args.committed.token) then
      args.store(args.committed)
    end
    return true, nil
  end)
end

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

  local commit_attempted = false
  local function currency(value)
    local epoch = contract_time.iso_timestamp_epoch_seconds(value)
    if epoch == nil then
      return nil
    end
    return H.commit_currency(string.format("%020d", epoch), value)
  end
  local function commit_effects(publish)
    if type(publish) ~= "function" then
      error("devloop: reconcile-effect-publisher-missing: commit_effects requires a publisher")
    end
    commit_attempted = true
    if context == nil or authoritative_epoch == nil then
      publish()
      return true
    end
    local planned = currency(authoritative)
    return H.commit({
      planned = planned,
      committed = planned,
      lock_key = context.key,
      refresh = function()
        if type(args.refresh_authoritative_version) ~= "function" then
          return planned
        end
        return currency(args.refresh_authoritative_version(prepared))
      end,
      load = function()
        return currency(cache_get(context.key))
      end,
      store = function(committed)
        cache_set(context.key, committed.token)
      end,
      publish = publish,
    })
  end

  local result = args.work(prepared, record_authoritative_version, commit_effects)
  if not commit_attempted and context ~= nil and authoritative_epoch ~= nil then
    commit_effects(function() end)
  end
  local reconciled = context and cache_get(context.key) or stored
  local reconciled_epoch = contract_time.iso_timestamp_epoch_seconds(reconciled)
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
