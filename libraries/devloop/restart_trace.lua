local error_facts = require("contract.error_facts")

local M = {}

local NULL = json.decode("null")
local ARRAY_TAG = getmetatable(json.decode("[]"))
local FINGERPRINT_PREFIX = "restart-grant-fingerprint.v1:"

local TRACE_FIELDS = {
  schema = true,
  owner = true,
  fixture_id = true,
  steps = true,
}

local STEP_FIELDS = {
  edge_id = true,
  row_replay_id = true,
  kind = true,
  source = true,
  target = true,
  cause_evidence = true,
  cas_policy_id = true,
  cas_status = true,
  reason_code = true,
  cas_outcome = true,
  pending_status = true,
  generation_epoch = true,
  grant_fingerprint = true,
  effect_entitlement_id = true,
  effect_ids = true,
  queue = true,
  payload_obligations = true,
  observable_writes = true,
  terminal_why = true,
}

local PENDING_STATUSES = {
  included = true,
  excluded = true,
  ["not-applicable"] = true,
}

local function fail(context, message)
  error("devloop.restart_trace: " .. context .. " " .. message, 0)
end

local function require_nonempty_string(value, context)
  if type(value) ~= "string" or value == "" then
    fail(context, "must be a non-empty string")
  end
end

local function validate_exact_fields(value, fields, context)
  if type(value) ~= "table" or value == NULL then
    fail(context, "must be an object")
  end
  for field in pairs(fields) do
    if rawget(value, field) == nil then
      fail(context, "is missing required field " .. field)
    end
  end
  for field in pairs(value) do
    if type(field) ~= "string" or fields[field] ~= true then
      fail(context, "contains unknown field " .. tostring(field))
    end
  end
end

local function array_length(value, context)
  if type(value) ~= "table" or value == NULL then
    fail(context, "must be an array")
  end
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      fail(context, "must be an array")
    end
    count = count + 1
    if key > maximum then
      maximum = key
    end
  end
  if maximum ~= count then
    fail(context, "must be a dense array")
  end
  if count == 0 and getmetatable(value) ~= ARRAY_TAG then
    fail(context, "must preserve an empty JSON array")
  end
  return count
end

local function validate_nullable_string(value, context)
  if value ~= NULL then
    require_nonempty_string(value, context)
  end
end

local function validate_serializable(value, context, seen)
  if value == NULL then
    return
  end
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then
    return
  end
  if kind ~= "table" then
    fail(context, "contains non-serializable " .. kind)
  end
  if seen[value] then
    fail(context, "contains a cycle")
  end
  seen[value] = true
  for key, nested in pairs(value) do
    local key_kind = type(key)
    if key_kind ~= "string" and key_kind ~= "number" then
      fail(context, "contains a non-serializable key")
    end
    if key_kind == "string" then
      local normalized = key:lower()
      if normalized ~= "grant_fingerprint" and normalized:find("grant", 1, true) ~= nil then
        fail(context, "must not serialize grants")
      end
      if normalized:find("seal", 1, true) ~= nil then
        fail(context, "must not serialize seals")
      end
      if normalized:find("secret", 1, true) ~= nil then
        fail(context, "must not serialize secrets")
      end
    end
    validate_serializable(nested, context .. "." .. tostring(key), seen)
  end
  seen[value] = nil
end

local function validate_step(step, index)
  local context = "steps[" .. tostring(index) .. "]"
  validate_exact_fields(step, STEP_FIELDS, context)

  local has_edge = step.edge_id ~= NULL
  local has_row_replay = step.row_replay_id ~= NULL
  if has_edge == has_row_replay then
    fail(context, "must identify exactly one edge_id or row_replay_id")
  end
  validate_nullable_string(step.edge_id, context .. ".edge_id")
  validate_nullable_string(step.row_replay_id, context .. ".row_replay_id")
  require_nonempty_string(step.kind, context .. ".kind")
  if type(step.source) ~= "table" or step.source == NULL then
    fail(context .. ".source", "must be an object")
  end
  validate_nullable_string(step.target, context .. ".target")
  if type(step.cause_evidence) ~= "table" or step.cause_evidence == NULL then
    fail(context .. ".cause_evidence", "must be an object")
  end
  require_nonempty_string(step.cas_policy_id, context .. ".cas_policy_id")
  require_nonempty_string(step.cas_status, context .. ".cas_status")
  require_nonempty_string(step.reason_code, context .. ".reason_code")
  require_nonempty_string(step.cas_outcome, context .. ".cas_outcome")
  if PENDING_STATUSES[step.pending_status] ~= true then
    fail(context .. ".pending_status", "must be included, excluded, or not-applicable")
  end
  if type(step.generation_epoch) ~= "table" or step.generation_epoch == NULL then
    fail(context .. ".generation_epoch", "must be an object")
  end

  if step.grant_fingerprint ~= NULL then
    require_nonempty_string(step.grant_fingerprint, context .. ".grant_fingerprint")
    if step.grant_fingerprint:match(
      "^restart%-grant%-fingerprint%.v1:fp%-%d+$"
    ) == nil then
      fail(context .. ".grant_fingerprint", "must be a non-secret restart grant fingerprint")
    end
  end
  validate_nullable_string(step.effect_entitlement_id, context .. ".effect_entitlement_id")
  local effect_count = array_length(step.effect_ids, context .. ".effect_ids")
  for ordinal = 1, effect_count do
    require_nonempty_string(step.effect_ids[ordinal], context .. ".effect_ids[" .. ordinal .. "]")
  end
  validate_nullable_string(step.queue, context .. ".queue")
  array_length(step.payload_obligations, context .. ".payload_obligations")
  array_length(step.observable_writes, context .. ".observable_writes")
  if step.terminal_why ~= NULL and type(step.terminal_why) ~= "table" then
    fail(context .. ".terminal_why", "must be an object or null")
  end

  validate_serializable(step, context, {})
end

function M.array(values)
  local result = json.decode("[]")
  for index, value in ipairs(values or {}) do
    result[index] = value
  end
  return result
end

function M.grant_fingerprint(fields)
  validate_exact_fields(fields, {
    snapshot_fingerprint = true,
    edge_id = true,
    effect_entitlement_id = true,
  }, "grant fingerprint fields")
  local parts = {}
  for _, field in ipairs({ "snapshot_fingerprint", "edge_id", "effect_entitlement_id" }) do
    local value = fields[field]
    require_nonempty_string(value, "grant fingerprint fields." .. field)
    table.insert(parts, field .. "=" .. value)
  end
  return FINGERPRINT_PREFIX .. error_facts.stable_hash(table.concat(parts, "\0"))
end

function M.define(trace)
  validate_exact_fields(trace, TRACE_FIELDS, "trace")
  if trace.schema ~= "restart-trace.v1" then
    fail("trace.schema", "must be restart-trace.v1")
  end
  require_nonempty_string(trace.owner, "trace.owner")
  require_nonempty_string(trace.fixture_id, "trace.fixture_id")
  local step_count = array_length(trace.steps, "trace.steps")
  if step_count == 0 then
    fail("trace.steps", "must contain at least one step")
  end
  for index = 1, step_count do
    validate_step(trace.steps[index], index)
  end
  validate_serializable(trace, "trace", {})
  return trace
end

M.null = NULL

return M
