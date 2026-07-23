local M = {}

local CASE_KINDS = {
  ["edge"] = true,
  ["edge-pair"] = true,
  ["family-variant"] = true,
  ["bounded-loop"] = true,
  ["cas-matrix"] = true,
  ["pending"] = true,
  ["entitlement"] = true,
  ["timeout"] = true,
}

local function require_nonempty_string(value, field)
  if type(value) ~= "string" or value == "" then
    error("devloop.restart_obligations: " .. field .. " must be a non-empty string")
  end
end

local function require_dense_string_array(value, field)
  if type(value) ~= "table" then
    error("devloop.restart_obligations: " .. field .. " must be an array of strings")
  end
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(item) ~= "string" then
      error("devloop.restart_obligations: " .. field .. " must be an array of strings")
    end
    count = count + 1
  end
  if count ~= #value then
    error("devloop.restart_obligations: " .. field .. " must be a dense array")
  end
end

local function validate_entry(entry, index, seen)
  local context = "entries[" .. tostring(index) .. "]"
  if type(entry) ~= "table" then
    error("devloop.restart_obligations: " .. context .. " must be a table")
  end
  for _, field in ipairs({
    "obligation_id",
    "owner",
    "edge_id",
    "input_fixture_id",
    "witness_id",
  }) do
    require_nonempty_string(entry[field], context .. "." .. field)
  end
  if seen[entry.obligation_id] then
    error("devloop.restart_obligations: duplicate obligation_id " .. entry.obligation_id)
  end
  seen[entry.obligation_id] = true
  if not CASE_KINDS[entry.case_kind] then
    error("devloop.restart_obligations: " .. context .. ".case_kind is invalid")
  end
  if type(entry.expected_decision) ~= "table" then
    error("devloop.restart_obligations: " .. context .. ".expected_decision must be a table")
  end
  require_dense_string_array(entry.expected_effect_ids, context .. ".expected_effect_ids")
  if type(entry.expected_payload_obligations) ~= "table" then
    error("devloop.restart_obligations: " .. context .. ".expected_payload_obligations must be a table")
  end
end

function M.define(entries)
  if type(entries) ~= "table" then
    error("devloop.restart_obligations: entries must be an array")
  end
  local seen = {}
  for index, entry in ipairs(entries) do
    validate_entry(entry, index, seen)
  end
  return entries
end

function M.derive_edge(owner_edges, witness_index)
  if type(owner_edges) ~= "table" then
    error("devloop.restart_obligations: owner_edges must be an array")
  end
  if type(witness_index) ~= "table" then
    error("devloop.restart_obligations: witness_index must be a table")
  end

  local obligations = {}
  local unmapped = {}
  local seen_edge_ids = {}
  local edge_count = 0
  for key, edge in pairs(owner_edges) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(edge) ~= "table" then
      error("devloop.restart_obligations: owner_edges must be an array of tables")
    end
    edge_count = edge_count + 1
  end
  if edge_count ~= #owner_edges then
    error("devloop.restart_obligations: owner_edges must be a dense array")
  end

  for _, edge in ipairs(owner_edges) do
    require_nonempty_string(edge.id, "owner_edges edge.id")
    require_nonempty_string(edge.owner, "owner_edges edge.owner")
    local pending_order = edge.pending_order
    if type(pending_order) ~= "table" or type(pending_order.participates) ~= "boolean" then
      error("devloop.restart_obligations: edge.pending_order.participates must be a boolean")
    end
    if pending_order.predecessor_state ~= nil then
      require_nonempty_string(
        pending_order.predecessor_state,
        "owner_edges edge.pending_order.predecessor_state"
      )
    elseif pending_order.participates then
      error("devloop.restart_obligations: participating edge must have a predecessor_state")
    end
    require_nonempty_string(edge.target, "owner_edges edge.target")
    require_nonempty_string(edge.kind, "owner_edges edge.kind")
    if seen_edge_ids[edge.id] then
      error("devloop.restart_obligations: duplicate edge id " .. edge.id)
    end
    seen_edge_ids[edge.id] = true

    local predecessor_state = pending_order.predecessor_state
    local witness = witness_index[edge.id]
    local unmapped_reason = nil
    if witness == nil then
      unmapped_reason = "missing-frozen-witness"
    elseif type(witness) ~= "table"
        or witness.owner ~= edge.owner
        or witness.edge_id ~= edge.id
        or witness.predecessor_state ~= predecessor_state
        or witness.target ~= edge.target
        or witness.kind ~= edge.kind
        or type(witness.expected_decision) ~= "table"
        or witness.expected_decision.predecessor_state ~= predecessor_state
        or witness.expected_decision.target ~= edge.target
        or witness.expected_decision.kind ~= edge.kind then
      unmapped_reason = "frozen-witness-edge-identity-mismatch"
    end

    if unmapped_reason ~= nil then
      table.insert(unmapped, {
        owner = edge.owner,
        edge_id = edge.id,
        predecessor_state = predecessor_state,
        target = edge.target,
        kind = edge.kind,
        reason = unmapped_reason,
      })
    else
      table.insert(obligations, {
        obligation_id = edge.id .. "/edge",
        owner = edge.owner,
        edge_id = edge.id,
        case_kind = "edge",
        input_fixture_id = witness.input_fixture_id,
        expected_decision = witness.expected_decision,
        expected_effect_ids = witness.expected_effect_ids,
        expected_payload_obligations = witness.expected_payload_obligations,
        witness_id = witness.witness_id,
      })
    end
  end

  M.define(obligations)
  return {
    obligations = obligations,
    unmapped = unmapped,
  }
end

function M.derive(owner_edges, witness_index)
  if type(owner_edges) ~= "table" then
    error("devloop.restart_obligations: owner_edges must be an array")
  end
  if type(witness_index) ~= "table" then
    error("devloop.restart_obligations: witness_index must be a table")
  end

  local obligations = {}
  local unmapped = {}
  local seen_edge_ids = {}
  local edge_count = 0
  for key, edge in pairs(owner_edges) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(edge) ~= "table" then
      error("devloop.restart_obligations: owner_edges must be an array of tables")
    end
    edge_count = edge_count + 1
  end
  if edge_count ~= #owner_edges then
    error("devloop.restart_obligations: owner_edges must be a dense array")
  end

  for _, edge in ipairs(owner_edges) do
    if edge.cas_policy_id ~= nil then
      require_nonempty_string(edge.id, "owner_edges edge.id")
      require_nonempty_string(edge.owner, "owner_edges edge.owner")
      require_nonempty_string(edge.cas_policy_id, "owner_edges edge.cas_policy_id")
      if seen_edge_ids[edge.id] then
        error("devloop.restart_obligations: duplicate CAS edge id " .. edge.id)
      end
      seen_edge_ids[edge.id] = true

      local witness = witness_index[edge.id]
      if witness == nil then
        table.insert(unmapped, {
          owner = edge.owner,
          edge_id = edge.id,
          cas_policy_id = edge.cas_policy_id,
          reason = "missing-frozen-witness",
        })
      elseif type(witness) ~= "table"
          or witness.owner ~= edge.owner
          or witness.edge_id ~= edge.id then
        table.insert(unmapped, {
          owner = edge.owner,
          edge_id = edge.id,
          cas_policy_id = edge.cas_policy_id,
          reason = "frozen-witness-identity-mismatch",
        })
      else
        table.insert(obligations, {
          obligation_id = edge.id .. "/cas-admission",
          owner = edge.owner,
          edge_id = edge.id,
          case_kind = "cas-matrix",
          input_fixture_id = witness.input_fixture_id,
          expected_decision = witness.expected_decision,
          expected_effect_ids = witness.expected_effect_ids,
          expected_payload_obligations = witness.expected_payload_obligations,
          witness_id = witness.witness_id,
        })
      end
    end
  end

  M.define(obligations)
  return {
    obligations = obligations,
    unmapped = unmapped,
  }
end

function M.derive_pending(owner_edges, witness_index)
  if type(owner_edges) ~= "table" then
    error("devloop.restart_obligations: owner_edges must be an array")
  end
  if type(witness_index) ~= "table" then
    error("devloop.restart_obligations: witness_index must be a table")
  end

  local obligations = {}
  local unmapped = {}
  local seen_edge_ids = {}
  local edge_count = 0
  for key, edge in pairs(owner_edges) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(edge) ~= "table" then
      error("devloop.restart_obligations: owner_edges must be an array of tables")
    end
    edge_count = edge_count + 1
  end
  if edge_count ~= #owner_edges then
    error("devloop.restart_obligations: owner_edges must be a dense array")
  end

  for _, edge in ipairs(owner_edges) do
    local pending_order = edge.pending_order
    if type(pending_order) ~= "table" or type(pending_order.participates) ~= "boolean" then
      error("devloop.restart_obligations: edge.pending_order.participates must be a boolean")
    end
    if pending_order.participates then
      require_nonempty_string(edge.id, "owner_edges edge.id")
      require_nonempty_string(edge.owner, "owner_edges edge.owner")
      require_nonempty_string(edge.target, "owner_edges edge.target")
      require_nonempty_string(
        pending_order.predecessor_state,
        "owner_edges edge.pending_order.predecessor_state"
      )
      if seen_edge_ids[edge.id] then
        error("devloop.restart_obligations: duplicate pending edge id " .. edge.id)
      end
      seen_edge_ids[edge.id] = true

      local witness = witness_index[edge.id]
      local unmapped_reason = nil
      if witness == nil then
        unmapped_reason = "missing-frozen-witness"
      elseif type(witness) ~= "table"
          or witness.owner ~= edge.owner
          or witness.edge_id ~= edge.id
          or witness.predecessor_state ~= pending_order.predecessor_state
          or witness.target ~= edge.target then
        unmapped_reason = "frozen-witness-identity-mismatch"
      end

      if unmapped_reason ~= nil then
        table.insert(unmapped, {
          owner = edge.owner,
          edge_id = edge.id,
          predecessor_state = pending_order.predecessor_state,
          target = edge.target,
          reason = unmapped_reason,
        })
      else
        table.insert(obligations, {
          obligation_id = edge.id .. "/pending-participation",
          owner = edge.owner,
          edge_id = edge.id,
          case_kind = "pending",
          input_fixture_id = witness.input_fixture_id,
          expected_decision = witness.expected_decision,
          expected_effect_ids = witness.expected_effect_ids,
          expected_payload_obligations = witness.expected_payload_obligations,
          witness_id = witness.witness_id,
        })
      end
    end
  end

  M.define(obligations)
  return {
    obligations = obligations,
    unmapped = unmapped,
  }
end

local function same_string_array(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
    return false
  end
  local left_count = 0
  for key, value in pairs(left) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(value) ~= "string" then
      return false
    end
    left_count = left_count + 1
  end
  if left_count ~= #left then
    return false
  end
  for index, value in ipairs(left) do
    if value ~= right[index] then
      return false
    end
  end
  return true
end

local function entitlement_expected_effect_ids(entitlements)
  local effect_ids = {}
  local seen = {}
  for _, status in ipairs({ "apply", "idempotent" }) do
    for _, effect_id in ipairs(entitlements[status].effect_ids) do
      if not seen[effect_id] then
        seen[effect_id] = true
        table.insert(effect_ids, effect_id)
      end
    end
  end
  return effect_ids
end

local function validate_entitlement_case(entitlements, status, context)
  local entitlement = entitlements[status]
  if type(entitlement) ~= "table" then
    error("devloop.restart_obligations: " .. context .. "." .. status .. " must be a table")
  end
  require_nonempty_string(entitlement.id, context .. "." .. status .. ".id")
  require_dense_string_array(entitlement.effect_ids, context .. "." .. status .. ".effect_ids")
end

local function witness_matches_entitlements(witness, edge, expected_effect_ids)
  if type(witness) ~= "table"
      or witness.owner ~= edge.owner
      or witness.edge_id ~= edge.id
      or type(witness.expected_decision) ~= "table"
      or type(witness.expected_decision.apply) ~= "table"
      or type(witness.expected_decision.idempotent) ~= "table"
      or witness.expected_decision.apply.effect_entitlement_id
        ~= edge.transition_effect_entitlements.apply.id
      or witness.expected_decision.idempotent.effect_entitlement_id
        ~= edge.transition_effect_entitlements.idempotent.id
      or not same_string_array(
        witness.expected_decision.apply.granted_effect_ids,
        edge.transition_effect_entitlements.apply.effect_ids
      )
      or not same_string_array(
        witness.expected_decision.idempotent.granted_effect_ids,
        edge.transition_effect_entitlements.idempotent.effect_ids
      )
      or not same_string_array(witness.expected_effect_ids, expected_effect_ids)
      or type(witness.expected_payload_obligations) ~= "table"
      or next(witness.expected_payload_obligations) ~= nil
      or type(witness.input_fixture_id) ~= "string"
      or witness.input_fixture_id == ""
      or type(witness.witness_id) ~= "string"
      or witness.witness_id == "" then
    return false
  end
  return true
end

function M.derive_entitlement(owner_edges, witness_index)
  if type(owner_edges) ~= "table" then
    error("devloop.restart_obligations: owner_edges must be an array")
  end
  if type(witness_index) ~= "table" then
    error("devloop.restart_obligations: witness_index must be a table")
  end

  local obligations = {}
  local unmapped = {}
  local seen_edge_ids = {}
  local edge_count = 0
  for key, edge in pairs(owner_edges) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(edge) ~= "table" then
      error("devloop.restart_obligations: owner_edges must be an array of tables")
    end
    edge_count = edge_count + 1
  end
  if edge_count ~= #owner_edges then
    error("devloop.restart_obligations: owner_edges must be a dense array")
  end

  for _, edge in ipairs(owner_edges) do
    local entitlements = edge.transition_effect_entitlements
    if entitlements ~= nil and type(entitlements) ~= "table" then
      error("devloop.restart_obligations: edge.transition_effect_entitlements must be a table")
    end
    if type(entitlements) == "table" and next(entitlements) ~= nil then
      require_nonempty_string(edge.id, "owner_edges edge.id")
      require_nonempty_string(edge.owner, "owner_edges edge.owner")
      validate_entitlement_case(entitlements, "apply", "edge.transition_effect_entitlements")
      validate_entitlement_case(entitlements, "idempotent", "edge.transition_effect_entitlements")
      if seen_edge_ids[edge.id] then
        error("devloop.restart_obligations: duplicate entitlement edge id " .. edge.id)
      end
      seen_edge_ids[edge.id] = true

      local expected_effect_ids = entitlement_expected_effect_ids(entitlements)
      local witness = witness_index[edge.id]
      local unmapped_reason = nil
      if witness == nil then
        unmapped_reason = "missing-frozen-witness"
      elseif not witness_matches_entitlements(witness, edge, expected_effect_ids) then
        unmapped_reason = "frozen-witness-entitlement-mismatch"
      end

      if unmapped_reason ~= nil then
        table.insert(unmapped, {
          owner = edge.owner,
          edge_id = edge.id,
          apply_entitlement_id = entitlements.apply.id,
          idempotent_entitlement_id = entitlements.idempotent.id,
          reason = unmapped_reason,
        })
      else
        table.insert(obligations, {
          obligation_id = edge.id .. "/effect-entitlement",
          owner = edge.owner,
          edge_id = edge.id,
          case_kind = "entitlement",
          input_fixture_id = witness.input_fixture_id,
          expected_decision = witness.expected_decision,
          expected_effect_ids = witness.expected_effect_ids,
          expected_payload_obligations = witness.expected_payload_obligations,
          witness_id = witness.witness_id,
        })
      end
    end
  end

  M.define(obligations)
  return {
    obligations = obligations,
    unmapped = unmapped,
  }
end

local function family_variant_groups(owner_edges)
  local groups = {}
  for _, edge in ipairs(owner_edges) do
    if edge.cas_variant ~= nil and edge.cas_policy_id == nil then
      error("devloop.restart_obligations: edge.cas_variant requires edge.cas_policy_id")
    end
    if edge.cas_policy_id ~= nil then
      require_nonempty_string(edge.cas_policy_id, "owner_edges edge.cas_policy_id")
    end
    if edge.cas_variant ~= nil then
      require_nonempty_string(edge.cas_variant, "owner_edges edge.cas_variant")
    end
    if edge.cas_policy_id ~= nil and edge.cas_variant ~= nil then
      local variants = groups[edge.cas_policy_id]
      if variants == nil then
        variants = {}
        groups[edge.cas_policy_id] = variants
      end
      variants[edge.cas_variant] = true
    end
  end
  return groups
end

local function has_multiple_variants(variants)
  local count = 0
  for _ in pairs(variants or {}) do
    count = count + 1
    if count > 1 then
      return true
    end
  end
  return false
end

function M.derive_family_variant(owner_edges, witness_index)
  if type(owner_edges) ~= "table" then
    error("devloop.restart_obligations: owner_edges must be an array")
  end
  if type(witness_index) ~= "table" then
    error("devloop.restart_obligations: witness_index must be a table")
  end

  local edge_count = 0
  for key, edge in pairs(owner_edges) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(edge) ~= "table" then
      error("devloop.restart_obligations: owner_edges must be an array of tables")
    end
    edge_count = edge_count + 1
  end
  if edge_count ~= #owner_edges then
    error("devloop.restart_obligations: owner_edges must be a dense array")
  end

  local groups = family_variant_groups(owner_edges)
  local obligations = {}
  local unmapped = {}
  local seen_edge_ids = {}
  for _, edge in ipairs(owner_edges) do
    if edge.cas_policy_id ~= nil and edge.cas_variant ~= nil
        and has_multiple_variants(groups[edge.cas_policy_id]) then
      require_nonempty_string(edge.id, "owner_edges edge.id")
      require_nonempty_string(edge.owner, "owner_edges edge.owner")
      require_nonempty_string(edge.target, "owner_edges edge.target")
      if seen_edge_ids[edge.id] then
        error("devloop.restart_obligations: duplicate family variant edge id " .. edge.id)
      end
      seen_edge_ids[edge.id] = true

      local witness = witness_index[edge.id]
      local unmapped_reason = nil
      if witness == nil then
        unmapped_reason = "missing-frozen-witness"
      elseif type(witness) ~= "table"
          or witness.owner ~= edge.owner
          or witness.edge_id ~= edge.id
          or witness.family_id ~= edge.cas_policy_id
          or witness.variant ~= edge.cas_variant
          or witness.target ~= edge.target
          or type(witness.expected_decision) ~= "table"
          or witness.expected_decision.family_id ~= edge.cas_policy_id
          or witness.expected_decision.variant ~= edge.cas_variant
          or witness.expected_decision.target_state ~= edge.target then
        unmapped_reason = "frozen-witness-family-variant-mismatch"
      end

      if unmapped_reason ~= nil then
        table.insert(unmapped, {
          owner = edge.owner,
          edge_id = edge.id,
          family_id = edge.cas_policy_id,
          variant = edge.cas_variant,
          reason = unmapped_reason,
        })
      else
        table.insert(obligations, {
          obligation_id = edge.id .. "/family-variant",
          owner = edge.owner,
          edge_id = edge.id,
          case_kind = "family-variant",
          input_fixture_id = witness.input_fixture_id,
          expected_decision = witness.expected_decision,
          expected_effect_ids = witness.expected_effect_ids,
          expected_payload_obligations = witness.expected_payload_obligations,
          witness_id = witness.witness_id,
        })
      end
    end
  end

  M.define(obligations)
  return {
    obligations = obligations,
    unmapped = unmapped,
  }
end

function M.derive_timeout(owner_edges, witness_index)
  if type(owner_edges) ~= "table" then
    error("devloop.restart_obligations: owner_edges must be an array")
  end
  if type(witness_index) ~= "table" then
    error("devloop.restart_obligations: witness_index must be a table")
  end

  local obligations = {}
  local unmapped = {}
  local seen_edge_ids = {}
  local edge_count = 0
  for key, edge in pairs(owner_edges) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(edge) ~= "table" then
      error("devloop.restart_obligations: owner_edges must be an array of tables")
    end
    edge_count = edge_count + 1
  end
  if edge_count ~= #owner_edges then
    error("devloop.restart_obligations: owner_edges must be a dense array")
  end

  for _, edge in ipairs(owner_edges) do
    local resolver = edge.timeout_evidence_policy_id
    if resolver ~= nil then
      require_nonempty_string(edge.id, "owner_edges edge.id")
      require_nonempty_string(edge.owner, "owner_edges edge.owner")
      require_nonempty_string(resolver, "owner_edges edge.timeout_evidence_policy_id")
      if seen_edge_ids[edge.id] then
        error("devloop.restart_obligations: duplicate timeout edge id " .. edge.id)
      end
      seen_edge_ids[edge.id] = true

      local witness = witness_index[edge.id]
      local unmapped_reason = nil
      if witness == nil then
        unmapped_reason = "missing-frozen-witness"
      elseif type(witness) ~= "table"
          or witness.owner ~= edge.owner
          or witness.edge_id ~= edge.id
          or witness.resolver ~= resolver
          or type(witness.actionable_epoch_source) ~= "string"
          or witness.actionable_epoch_source == ""
          or type(witness.expected_decision) ~= "table"
          or witness.expected_decision.actionable_epoch_source
            ~= witness.actionable_epoch_source
          or witness.expected_decision.resolver ~= resolver then
        unmapped_reason = "frozen-witness-timeout-resolver-mismatch"
      end

      if unmapped_reason ~= nil then
        table.insert(unmapped, {
          owner = edge.owner,
          edge_id = edge.id,
          resolver = resolver,
          reason = unmapped_reason,
        })
      else
        table.insert(obligations, {
          obligation_id = edge.id .. "/timeout-resolver",
          owner = edge.owner,
          edge_id = edge.id,
          case_kind = "timeout",
          input_fixture_id = witness.input_fixture_id,
          expected_decision = witness.expected_decision,
          expected_effect_ids = witness.expected_effect_ids,
          expected_payload_obligations = witness.expected_payload_obligations,
          witness_id = witness.witness_id,
        })
      end
    end
  end

  M.define(obligations)
  return {
    obligations = obligations,
    unmapped = unmapped,
  }
end

return M
