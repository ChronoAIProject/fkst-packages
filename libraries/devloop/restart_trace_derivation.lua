local restart_trace = require("devloop.restart_trace")

local M = {}

local NULL = restart_trace.null
local ARRAY_TAG = getmetatable(json.decode("[]"))

local function fail(message)
  error("devloop.restart_trace_derivation: " .. message, 0)
end

local function require_nonempty_string(value, field)
  if type(value) ~= "string" or value == "" then
    fail(field .. " must be a non-empty string")
  end
end

local function validate_fields(value, required, optional, context)
  if type(value) ~= "table" or value == NULL then
    fail(context .. " must be an object")
  end
  local allowed = {}
  for _, field in ipairs(required) do
    allowed[field] = true
    if rawget(value, field) == nil then
      fail(context .. " is missing field " .. field)
    end
  end
  for _, field in ipairs(optional or {}) do
    allowed[field] = true
  end
  for field in pairs(value) do
    if type(field) ~= "string" or allowed[field] ~= true then
      fail(context .. " contains unknown field " .. tostring(field))
    end
  end
end

local function array_length(value, context)
  if type(value) ~= "table" or value == NULL then
    fail(context .. " must be an array")
  end
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      fail(context .. " must be an array")
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then
    fail(context .. " must be a dense array")
  end
  return count
end

local function deep_equal(left, right, seen)
  if left == right then
    return true
  end
  if type(left) ~= type(right) or type(left) ~= "table" then
    return false
  end
  seen = seen or {}
  if seen[left] == right then
    return true
  end
  seen[left] = right
  for key, value in pairs(left) do
    if not deep_equal(value, right[key], seen) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function clone(value, seen)
  if value == NULL or type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] ~= nil then
    fail("frozen witness contains a cycle")
  end
  seen[value] = true
  local count = 0
  local maximum = 0
  local numeric_only = true
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      numeric_only = false
    else
      count = count + 1
      maximum = math.max(maximum, key)
    end
  end
  local is_array = getmetatable(value) == ARRAY_TAG
    or (numeric_only and count > 0 and count == maximum)
  local result = is_array and restart_trace.array() or {}
  for key, nested in pairs(value) do
    result[clone(key, seen)] = clone(nested, seen)
  end
  seen[value] = nil
  return result
end

local function nullable(value)
  return value == nil and NULL or value
end

local function clone_array(value)
  local result = restart_trace.array()
  for _, item in ipairs(value) do
    table.insert(result, clone(item))
  end
  return result
end

local function expected_entitlement(edge, obligation)
  local status = obligation.expected_decision.cas_status
  if status ~= "apply" and status ~= "idempotent" then
    if status ~= "pending" and status ~= "stale" then
      fail("expected_decision.cas_status is not a mapped CAS-admission status")
    end
    if #obligation.expected_effect_ids ~= 0 then
      fail("non-entitled CAS decision must not expect effects")
    end
    return NULL
  end

  local entitlements = edge.transition_effect_entitlements
  local entitlement = type(entitlements) == "table" and entitlements[status] or nil
  if type(entitlement) ~= "table" then
    fail("edge is missing the expected effect entitlement")
  end
  require_nonempty_string(entitlement.id, "edge effect entitlement id")
  array_length(entitlement.effect_ids, "edge effect entitlement effect_ids")
  if not deep_equal(entitlement.effect_ids, obligation.expected_effect_ids) then
    fail("R5 expected effects drift from the canonical edge entitlement")
  end
  return entitlement.id
end

local function cause_evidence(edge, trace_witness)
  local result = {}
  if edge.timeout_evidence_policy_id ~= nil then
    require_nonempty_string(
      edge.timeout_evidence_policy_id,
      "edge.timeout_evidence_policy_id"
    )
    result.timeout_evidence_policy_id = edge.timeout_evidence_policy_id
  elseif edge.source.boundary ~= nil then
    require_nonempty_string(edge.source.boundary, "edge.source.boundary")
    result.source_boundary = edge.source.boundary
  end

  local frozen = trace_witness.frozen_observation
  if frozen ~= nil then
    validate_fields(
      frozen,
      { "id", "status", "reason_code", "cas_outcome" },
      nil,
      "witness.trace.frozen_observation"
    )
    for _, field in ipairs({ "id", "status", "reason_code", "cas_outcome" }) do
      require_nonempty_string(frozen[field], "witness.trace.frozen_observation." .. field)
    end
    result.frozen_observation_id = frozen.id
    result.frozen_status = frozen.status
    result.frozen_reason_code = frozen.reason_code
    result.frozen_cas_outcome = frozen.cas_outcome
  end
  return result
end

function M.derive_cas_admission(edge, obligation, witness)
  validate_fields(edge, {
    "id",
    "owner",
    "kind",
    "source",
    "target",
    "cas_policy_id",
    "pending_order",
    "transition_effect_entitlements",
  }, {
    "row_id",
    "semantic_variant",
    "provenance",
    "cas_variant",
    "timeout_evidence_policy_id",
    "cause_evidence",
    "generation_epoch",
    "lineage_keys",
  }, "edge")
  validate_fields(obligation, {
    "obligation_id",
    "owner",
    "edge_id",
    "case_kind",
    "input_fixture_id",
    "expected_decision",
    "expected_effect_ids",
    "expected_payload_obligations",
    "witness_id",
  }, nil, "obligation")
  validate_fields(witness, {
    "owner",
    "edge_id",
    "input_fixture_id",
    "witness_id",
    "expected_decision",
    "expected_effect_ids",
    "expected_payload_obligations",
    "trace",
  }, nil, "witness")
  validate_fields(witness.trace, {
    "snapshot_fingerprint",
    "generation_epoch",
    "effect_entitlement_id",
    "queue",
    "observable_writes",
    "terminal_why",
  }, { "frozen_observation" }, "witness.trace")

  require_nonempty_string(edge.id, "edge.id")
  require_nonempty_string(edge.owner, "edge.owner")
  require_nonempty_string(edge.kind, "edge.kind")
  require_nonempty_string(edge.target, "edge.target")
  require_nonempty_string(edge.cas_policy_id, "edge.cas_policy_id")
  if type(edge.source) ~= "table" or edge.source == NULL then
    fail("edge.source must be an object")
  end
  if type(edge.pending_order) ~= "table"
    or type(edge.pending_order.participates) ~= "boolean" then
    fail("edge.pending_order.participates must be a boolean")
  end

  if obligation.case_kind ~= "cas-matrix"
    or obligation.obligation_id ~= edge.id .. "/cas-admission" then
    fail("obligation is not a mapped CAS-admission obligation")
  end
  for _, field in ipairs({ "owner", "edge_id", "input_fixture_id", "witness_id" }) do
    require_nonempty_string(obligation[field], "obligation." .. field)
    require_nonempty_string(witness[field], "witness." .. field)
    if obligation[field] ~= witness[field] then
      fail("obligation and frozen witness disagree on " .. field)
    end
  end
  if obligation.owner ~= edge.owner or obligation.edge_id ~= edge.id then
    fail("obligation is not owned by the canonical edge")
  end

  validate_fields(
    obligation.expected_decision,
    { "cas_status", "reason_code", "cas_outcome" },
    { "frozen_status", "frozen_reason_code", "frozen_cas_outcome" },
    "obligation.expected_decision"
  )
  validate_fields(
    witness.expected_decision,
    { "cas_status", "reason_code", "cas_outcome" },
    { "frozen_status", "frozen_reason_code", "frozen_cas_outcome" },
    "witness.expected_decision"
  )
  for _, field in ipairs({ "cas_status", "reason_code", "cas_outcome" }) do
    require_nonempty_string(obligation.expected_decision[field], "obligation.expected_decision." .. field)
    if obligation.expected_decision[field] ~= witness.expected_decision[field] then
      fail("R5 decision drifts from the frozen witness")
    end
  end

  local effect_count = array_length(obligation.expected_effect_ids, "obligation.expected_effect_ids")
  array_length(witness.expected_effect_ids, "witness.expected_effect_ids")
  local payload_count = array_length(
    obligation.expected_payload_obligations,
    "obligation.expected_payload_obligations"
  )
  array_length(
    witness.expected_payload_obligations,
    "witness.expected_payload_obligations"
  )
  if not deep_equal(obligation.expected_effect_ids, witness.expected_effect_ids)
    or not deep_equal(
      obligation.expected_payload_obligations,
      witness.expected_payload_obligations
    ) then
    fail("R5 effects or payload obligations drift from the frozen witness")
  end
  if payload_count ~= effect_count then
    fail("each expected effect must have one payload obligation")
  end
  for index, payload in ipairs(obligation.expected_payload_obligations) do
    validate_fields(payload, { "effect_id", "equality" }, nil,
      "obligation.expected_payload_obligations[" .. tostring(index) .. "]")
    if payload.effect_id ~= obligation.expected_effect_ids[index] then
      fail("payload obligation effect order drifts from R5 effects")
    end
    require_nonempty_string(payload.equality, "payload obligation equality")
  end

  local entitlement_id = expected_entitlement(edge, obligation)
  if witness.trace.effect_entitlement_id ~= entitlement_id then
    fail("effect entitlement drifts from the canonical edge and frozen witness")
  end
  require_nonempty_string(witness.trace.snapshot_fingerprint, "witness.trace.snapshot_fingerprint")
  if witness.trace.queue ~= NULL then
    require_nonempty_string(witness.trace.queue, "witness.trace.queue")
  end
  if edge.source.boundary ~= nil and witness.trace.queue ~= edge.source.boundary then
    fail("trace queue drifts from the canonical edge boundary")
  end
  local write_count = array_length(witness.trace.observable_writes, "witness.trace.observable_writes")
  if write_count ~= effect_count then
    fail("observable writes must match the expected effect count")
  end
  if witness.trace.terminal_why ~= NULL and type(witness.trace.terminal_why) ~= "table" then
    fail("witness.trace.terminal_why must be an object or null")
  end

  local generation = witness.trace.generation_epoch
  validate_fields(generation, {
    "current_version",
    "incoming_version",
    "generation",
    "lock_epoch",
  }, nil, "witness.trace.generation_epoch")
  for _, field in ipairs({ "current_version", "incoming_version", "generation", "lock_epoch" }) do
    if generation[field] ~= NULL then
      require_nonempty_string(generation[field], "witness.trace.generation_epoch." .. field)
    end
  end

  local fingerprint = NULL
  if effect_count > 0 then
    fingerprint = restart_trace.grant_fingerprint({
      snapshot_fingerprint = witness.trace.snapshot_fingerprint,
      edge_id = edge.id,
      effect_entitlement_id = entitlement_id,
    })
  end

  return restart_trace.define({
    schema = "restart-trace.v1",
    owner = edge.owner,
    fixture_id = obligation.input_fixture_id,
    steps = restart_trace.array({
      {
        edge_id = edge.id,
        row_replay_id = NULL,
        kind = edge.kind,
        source = {
          state = nullable(edge.source.state),
          boundary = nullable(edge.source.boundary),
        },
        target = edge.target,
        cause_evidence = cause_evidence(edge, witness.trace),
        cas_policy_id = edge.cas_policy_id,
        cas_status = obligation.expected_decision.cas_status,
        reason_code = obligation.expected_decision.reason_code,
        cas_outcome = obligation.expected_decision.cas_outcome,
        pending_status = edge.pending_order.participates and "included" or "excluded",
        generation_epoch = clone(generation),
        grant_fingerprint = fingerprint,
        effect_entitlement_id = entitlement_id,
        effect_ids = clone_array(obligation.expected_effect_ids),
        queue = witness.trace.queue,
        payload_obligations = clone_array(obligation.expected_payload_obligations),
        observable_writes = clone_array(witness.trace.observable_writes),
        terminal_why = clone(witness.trace.terminal_why),
      },
    }),
  })
end

return M
