local core = require("core")
local restart_effect_entitlements = require("devloop.restart_effect_entitlements")
local restart_metadata = require("devloop.restart_metadata")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local entity_lib = require("devloop.entity")
local entity_highwater = require("devloop.entity_highwater")

local owner = core.restart_package_name
local restart_authority = require("core.restart_authority")
local rows = core.restart_transition_table()
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local edges = owner_pending_projection.edges(owner, rows, inventories)
local sinks = require("core.restart.sink_inventory")
local receiver_dispatch = require("devloop.restart_receiver_dispatch").index(owner, rows)

local M = {}
local owner_seal = function() end
local sealed_snapshots = setmetatable({}, { __mode = "k" })
local sealed_decisions = setmetatable({}, { __mode = "k" })
local issued_grants = setmetatable({}, { __mode = "k" })

local is_nonempty_string = restart_metadata.is_nonempty_string
local copy_value = restart_metadata.copy_value
local copy_array = restart_metadata.copy_array
local arrays_equal = restart_metadata.arrays_equal

local edges_by_id = {}
for _, edge in ipairs(edges) do
  edges_by_id[edge.id] = edge
end

local sinks_by_id = {}
for _, sink in ipairs(sinks) do
  sinks_by_id[sink.id] = sink
end

local function pr_illegal_decision(reason_code)
  return {
    status = "illegal",
    reason_code = reason_code,
    cas_outcome = "illegal(" .. reason_code .. ")",
    granted_effect_ids = {},
    grant = nil,
  }
end

local function pr_snapshot_record(snapshot)
  local record = sealed_snapshots[snapshot]
  if record == nil
    or type(snapshot) ~= "table"
    or snapshot._owner_snapshot_seal ~= record.snapshot_seal then
    return nil
  end
  return record
end

local function complete_pr_grant_binding(record, decision_record)
  local fields = record.fields
  local entity = fields.entity
  local current = fields.current
  local authority = decision_record.authority
  if type(entity) ~= "table"
    or not is_nonempty_string(entity.kind)
    or not is_nonempty_string(entity.repo)
    or entity.number == nil
    or not is_nonempty_string(fields.snapshot_fingerprint)
    or not is_nonempty_string(fields.lock_epoch)
    or not is_nonempty_string(fields.generation)
    or type(current) ~= "table"
    or not is_nonempty_string(current.version)
    or type(authority) ~= "table"
    or not is_nonempty_string(authority.target) then
    return nil
  end
  return {
    owner_seal = owner_seal,
    authority_kind = authority.kind,
    edge_id = decision_record.result.edge_id,
    receiver_dispatch_id = decision_record.result.receiver_dispatch_id,
    row_replay_id = decision_record.result.row_replay_id,
    entity = copy_value(entity),
    snapshot = decision_record.snapshot,
    snapshot_fingerprint = fields.snapshot_fingerprint,
    lock_epoch = fields.lock_epoch,
    target = authority.target,
    version = current.version,
    generation = fields.generation,
    decision_status = decision_record.result.status,
    effect_entitlement_id = decision_record.entitlement.id,
    effect_ids = copy_array(decision_record.entitlement.effect_ids),
    incoming_version = decision_record.result.incoming_version,
    target_version = decision_record.result.target_version,
  }
end

local function mint_pr_grant(binding)
  local grant_seal = function() end
  local grant = { _owner_grant_seal = grant_seal }
  local remaining = {}
  for _, effect_id in ipairs(binding.effect_ids) do
    remaining[effect_id] = (remaining[effect_id] or 0) + 1
  end
  binding.grant_seal = grant_seal
  binding.remaining = remaining
  issued_grants[grant] = binding
  return grant
end

local function seal_pr_snapshot(fields)
  if type(fields) ~= "table" or fields.owner ~= owner then
    error("restart-effects: snapshot-owner-mismatch: owner must be " .. tostring(owner))
  end

  local snapshot_seal = function() end
  local snapshot = {
    owner = owner,
    entity = copy_value(fields.entity),
    proposal_id = fields.proposal_id,
    current = copy_value(fields.current or {}),
    claim = copy_value(fields.claim),
    head = copy_value(fields.head),
    base = copy_value(fields.base),
    snapshot_fingerprint = fields.snapshot_fingerprint,
    lock_epoch = fields.lock_epoch,
    generation = fields.generation,
    _owner_snapshot_seal = snapshot_seal,
  }
  sealed_snapshots[snapshot] = {
    snapshot_seal = snapshot_seal,
    fields = copy_value(snapshot),
  }
  return snapshot
end

local function decide_pr_transition(sealed_snapshot, intent)
  local record = pr_snapshot_record(sealed_snapshot)
  if record == nil then
    return pr_illegal_decision("unsealed-or-foreign-snapshot")
  end

  local fields = record.fields
  local authority_snapshot = restart_authority.seal_snapshot({
    owner = owner,
    proposal_id = fields.proposal_id,
    current = copy_value(fields.current),
  })
  local result = restart_authority.decide_transition(authority_snapshot, intent)
  result.grant = nil
  result.current_fingerprint = fields.snapshot_fingerprint

  local decision_record = {
    snapshot = sealed_snapshot,
    result = copy_value(result),
  }
  if result.status == "apply" or result.status == "idempotent" then
    local edge = edges_by_id[result.edge_id]
    if edge == nil or edge.owner ~= owner then
      local rejected = pr_illegal_decision("unknown-or-foreign-edge")
      sealed_decisions[rejected] = { snapshot = sealed_snapshot, result = copy_value(rejected) }
      return rejected
    end
    if type(edge.transition_effect_entitlements) ~= "table" then
      local rejected = pr_illegal_decision("unsupported-effect-entitlement")
      rejected.edge_id = edge.id
      sealed_decisions[rejected] = { snapshot = sealed_snapshot, result = copy_value(rejected) }
      return rejected
    end

    local entitlement = restart_effect_entitlements.resolve(edge, result.status)
    if result.effect_entitlement_id ~= entitlement.id
      or not arrays_equal(result.granted_effect_ids, entitlement.effect_ids) then
      local rejected = pr_illegal_decision("effect-entitlement-drift")
      rejected.edge_id = edge.id
      sealed_decisions[rejected] = { snapshot = sealed_snapshot, result = copy_value(rejected) }
      return rejected
    end
    decision_record.edge = edge
    decision_record.authority = edge
    decision_record.entitlement = entitlement
  end
  sealed_decisions[result] = decision_record
  return result
end

local function decide_pr_receiver_dispatch(sealed_snapshot, intent)
  local record = pr_snapshot_record(sealed_snapshot)
  if record == nil then
    return pr_illegal_decision("unsealed-or-foreign-snapshot")
  end
  local fields = record.fields
  local authority_snapshot = restart_authority.seal_snapshot({
    owner = owner,
    proposal_id = fields.proposal_id,
    current = copy_value(fields.current),
  })
  local result = restart_authority.decide_receiver_dispatch(authority_snapshot, intent)
  result.grant = nil
  result.current_fingerprint = fields.snapshot_fingerprint
  local decision_record = { snapshot = sealed_snapshot, result = copy_value(result) }
  if result.status == "apply" or result.status == "idempotent" then
    local receiver = receiver_dispatch[result.receiver_state]
    if receiver == nil
      or result.receiver_dispatch_id ~= receiver.entitlement.id
      or result.effect_entitlement_id ~= receiver.entitlement.id
      or not arrays_equal(result.granted_effect_ids, receiver.entitlement.effect_ids) then
      local rejected = pr_illegal_decision("receiver-effect-entitlement-drift")
      sealed_decisions[rejected] = { snapshot = sealed_snapshot, result = copy_value(rejected) }
      return rejected
    end
    decision_record.authority = {
      id = receiver.entitlement.id,
      kind = "receiver-dispatch",
      target = receiver.receiver_state,
    }
    decision_record.entitlement = receiver.entitlement
  end
  sealed_decisions[result] = decision_record
  return result
end

local function assert_pr_decision_admissible(decision, error_prefix)
  if decision.status == "illegal" then
    error(error_prefix .. ": " .. tostring(decision.reason_code))
  end
end

local function mint_pr_effect_grant(sealed_snapshot, decision_result, sink_id)
  local snapshot = pr_snapshot_record(sealed_snapshot)
  local decision = sealed_decisions[decision_result]
  local sink = sinks_by_id[sink_id]
  if snapshot == nil
    or decision == nil
    or decision.snapshot ~= sealed_snapshot
    or sink == nil
    or sink.owner ~= owner
    or sink.authority_class ~= "lifecycle-authoritative"
    or decision.minted == true
    or (decision.result.status ~= "apply" and decision.result.status ~= "idempotent")
    or decision.entitlement == nil
    or decision.authority == nil then
    return nil
  end

  if decision.result.status == "idempotent" and #decision.entitlement.effect_ids == 0 then
    decision.minted = true
    return nil
  end

  local binding = complete_pr_grant_binding(snapshot, decision)
  if binding == nil then
    return nil
  end
  decision.minted = true
  return mint_pr_grant(binding)
end

local function verify_pr_effect_grant(grant, expected_effect_id, expected_snapshot)
  local binding = issued_grants[grant]
  if binding ~= nil and expected_snapshot == nil then
    expected_snapshot = binding.snapshot
  end
  local snapshot = pr_snapshot_record(expected_snapshot)
  if binding == nil
    or snapshot == nil
    or binding.owner_seal ~= owner_seal
    or grant._owner_grant_seal ~= binding.grant_seal
    or binding.snapshot ~= expected_snapshot
    or binding.snapshot_fingerprint ~= snapshot.fields.snapshot_fingerprint
    or binding.lock_epoch ~= snapshot.fields.lock_epoch
    or binding.version ~= snapshot.fields.current.version
    or binding.generation ~= snapshot.fields.generation
    or binding.remaining[expected_effect_id] == nil
    or binding.remaining[expected_effect_id] < 1 then
    return false
  end

  binding.remaining[expected_effect_id] = binding.remaining[expected_effect_id] - 1
  return true
end

local function pr_lifecycle_currency(state, version, fallback_order)
  if state == nil then
    return entity_highwater.commit_currency(fallback_order, "source:nil")
  end
  if not is_nonempty_string(state) or not is_nonempty_string(version) then
    return nil
  end
  return entity_highwater.commit_currency(
    restart_metadata.marker_order_key(version, state),
    "state:" .. tostring(#state) .. ":" .. state .. ":version:" .. tostring(#version) .. ":" .. version
  )
end

local function commit_pr_effect_grant(grant, expected_snapshot, opts)
  local binding = issued_grants[grant]
  local snapshot = pr_snapshot_record(expected_snapshot)
  if binding == nil
    or snapshot == nil
    or binding.snapshot ~= expected_snapshot
    or binding.committed == true
    or type(opts) ~= "table"
    or type(opts.refresh_current) ~= "function"
    or type(opts.publish) ~= "function" then
    return false, "grant-invalid"
  end
  for _, effect_id in ipairs(binding.effect_ids) do
    if binding.remaining[effect_id] ~= 0 then
      return false, "grant-effects-unconsumed"
    end
  end

  local target_version = binding.target_version or binding.incoming_version or binding.version
  local committed = pr_lifecycle_currency(binding.target, target_version)
  if committed == nil then
    error("github-devloop: restart-effect-commit-target-invalid: target state and version are required")
  end
  local source_state = snapshot.fields.current.state
  local source_version = source_state == nil and nil or snapshot.fields.current.version
  local planned = pr_lifecycle_currency(source_state, source_version, committed.order)
  local lock_key = entity_lib.transition_lock_key(snapshot.fields.proposal_id)
  if planned == nil or lock_key == nil then
    error("github-devloop: restart-effect-commit-source-invalid: source currency and transition lock are required")
  end
  local cache_key = entity_highwater.commit_cache_key(lock_key, owner .. "-lifecycle")
  local accepted, reason = entity_highwater.commit({
    planned = planned,
    committed = committed,
    lock_key = lock_key,
    refresh = function()
      local current = opts.refresh_current()
      if current == false then
        return nil
      end
      local state = type(current) == "table" and current.state or nil
      local version = state == nil and nil or current.version
      return pr_lifecycle_currency(state, version, committed.order)
    end,
    load = function() return entity_highwater.commit_cache_load(cache_key) end,
    store = function(value) entity_highwater.commit_cache_store(cache_key, value) end,
    publish = opts.publish,
  })
  if accepted then
    binding.committed = true
  end
  return accepted, reason
end

M.seal_snapshot = seal_pr_snapshot
M.decide_transition = decide_pr_transition
M.decide_receiver_dispatch = decide_pr_receiver_dispatch
M.assert_decision_admissible = assert_pr_decision_admissible
M.mint_grant = mint_pr_effect_grant
M.verify_grant = verify_pr_effect_grant
M.commit_grant = commit_pr_effect_grant

return M
