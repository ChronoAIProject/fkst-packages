local restart_effect_entitlements = require("devloop.restart_effect_entitlements")
local restart_metadata = require("devloop.restart_metadata")

local M = {}

local is_nonempty_string = restart_metadata.is_nonempty_string
local copy_value = restart_metadata.copy_value
local copy_array = restart_metadata.copy_array
local arrays_equal = restart_metadata.arrays_equal

function M.make(config)
  local owner = config.owner
  local restart_authority = config.restart_authority
  local owner_seal = function() end
  local sealed_snapshots = setmetatable({}, { __mode = "k" })
  local sealed_decisions = setmetatable({}, { __mode = "k" })
  local issued_grants = setmetatable({}, { __mode = "k" })

  local edges_by_id = {}
  for _, edge in ipairs(config.edges) do
    edges_by_id[edge.id] = edge
  end

  local sinks_by_id = {}
  for _, sink in ipairs(config.sinks) do
    sinks_by_id[sink.id] = sink
  end

  local facade = {}

  local function illegal(reason_code)
    return {
      status = "illegal",
      reason_code = reason_code,
      cas_outcome = "illegal(" .. reason_code .. ")",
      granted_effect_ids = {},
      grant = nil,
    }
  end

  local function snapshot_record(snapshot)
    local record = sealed_snapshots[snapshot]
    if record == nil
      or type(snapshot) ~= "table"
      or snapshot._owner_snapshot_seal ~= record.snapshot_seal then
      return nil
    end
    return record
  end

  local function complete_grant_binding(record, decision_record)
    local fields = record.fields
    local entity = fields.entity
    local current = fields.current
    if type(entity) ~= "table"
      or not is_nonempty_string(entity.kind)
      or not is_nonempty_string(entity.repo)
      or entity.number == nil
      or not is_nonempty_string(fields.snapshot_fingerprint)
      or not is_nonempty_string(fields.lock_epoch)
      or not is_nonempty_string(fields.generation)
      or type(current) ~= "table"
      or not is_nonempty_string(current.version)
      or type(decision_record.edge) ~= "table"
      or not is_nonempty_string(decision_record.edge.target) then
      return nil
    end
    return {
      owner_seal = owner_seal,
      authority_kind = decision_record.edge.kind,
      edge_id = decision_record.edge.id,
      row_replay_id = decision_record.result.row_replay_id,
      entity = copy_value(entity),
      snapshot = decision_record.snapshot,
      snapshot_fingerprint = fields.snapshot_fingerprint,
      lock_epoch = fields.lock_epoch,
      target = decision_record.edge.target,
      version = current.version,
      generation = fields.generation,
      decision_status = decision_record.result.status,
      effect_entitlement_id = decision_record.entitlement.id,
      effect_ids = copy_array(decision_record.entitlement.effect_ids),
    }
  end

  local function mint(binding)
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

  function facade.seal_snapshot(fields)
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

  function facade.decide_transition(sealed_snapshot, intent)
    local record = snapshot_record(sealed_snapshot)
    if record == nil then
      return illegal("unsealed-or-foreign-snapshot")
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
        local rejected = illegal("unknown-or-foreign-edge")
        sealed_decisions[rejected] = { snapshot = sealed_snapshot, result = copy_value(rejected) }
        return rejected
      end
      if type(edge.transition_effect_entitlements) ~= "table" then
        local rejected = illegal("unsupported-effect-entitlement")
        rejected.edge_id = edge.id
        sealed_decisions[rejected] = { snapshot = sealed_snapshot, result = copy_value(rejected) }
        return rejected
      end

      local entitlement = restart_effect_entitlements.resolve(edge, result.status)
      if result.effect_entitlement_id ~= entitlement.id
        or not arrays_equal(result.granted_effect_ids, entitlement.effect_ids) then
        local rejected = illegal("effect-entitlement-drift")
        rejected.edge_id = edge.id
        sealed_decisions[rejected] = { snapshot = sealed_snapshot, result = copy_value(rejected) }
        return rejected
      end
      decision_record.edge = edge
      decision_record.entitlement = entitlement
    end
    sealed_decisions[result] = decision_record
    return result
  end

  function facade.mint_grant(sealed_snapshot, decision_result, sink_id)
    local snapshot = snapshot_record(sealed_snapshot)
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
      or decision.entitlement == nil then
      return nil
    end

    if decision.result.status == "idempotent" and #decision.entitlement.effect_ids == 0 then
      decision.minted = true
      return nil
    end

    local binding = complete_grant_binding(snapshot, decision)
    if binding == nil then
      return nil
    end
    decision.minted = true
    return mint(binding)
  end

  function facade.verify_grant(grant, expected_effect_id, expected_snapshot)
    local binding = issued_grants[grant]
    if binding ~= nil and expected_snapshot == nil then
      expected_snapshot = binding.snapshot
    end
    local snapshot = snapshot_record(expected_snapshot)
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

  return facade
end

return M
