local M = {}

local function same_array(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
    return false
  end
  for index, value in ipairs(left) do
    if value ~= right[index] then return false end
  end
  return true
end

function M.new(primitives)
  local K = {}
  local define = primitives.define
  local require_nonempty_string = primitives.require_nonempty_string
  local require_dense_string_array = primitives.require_dense_string_array

  function K.derive_generation(owner_edges, witness_index)
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

    local obligations = {}
    local unmapped = {}
    local seen_edge_ids = {}
    for _, edge in ipairs(owner_edges) do
      require_nonempty_string(edge.id, "owner_edges edge.id")
      require_nonempty_string(edge.owner, "owner_edges edge.owner")
      local generation = edge.generation_epoch
      if type(generation) ~= "table"
          or (generation.mode ~= "preserve"
            and generation.mode ~= "bump"
            and generation.mode ~= "open") then
        error("devloop.restart_obligations: edge.generation_epoch.mode is invalid")
      end
      require_dense_string_array(generation.keys, "owner_edges edge.generation_epoch.keys")
      require_dense_string_array(edge.lineage_keys, "owner_edges edge.lineage_keys")
      if generation.mode == "preserve" and #generation.keys ~= 0 then
        error("devloop.restart_obligations: preserving edge generation keys must be empty")
      end

      if generation.mode == "bump" or generation.mode == "open" then
        if #generation.keys == 0 or #edge.lineage_keys == 0 then
          error("devloop.restart_obligations: generation edge keys must be non-empty")
        end
        if seen_edge_ids[edge.id] then
          error("devloop.restart_obligations: duplicate generation edge id " .. edge.id)
        end
        seen_edge_ids[edge.id] = true
        local witness = witness_index[edge.id]
        local reason = nil
        if witness == nil then
          reason = "missing-frozen-witness"
        elseif type(witness) ~= "table"
            or witness.owner ~= edge.owner
            or witness.edge_id ~= edge.id
            or type(witness.generation_epoch) ~= "table"
            or witness.generation_epoch.mode ~= generation.mode
            or not same_array(witness.generation_epoch.keys, generation.keys)
            or not same_array(witness.lineage_keys, edge.lineage_keys)
            or type(witness.expected_decision) ~= "table"
            or witness.expected_decision.mode ~= generation.mode
            or not same_array(witness.expected_decision.keys, generation.keys)
            or not same_array(witness.expected_decision.lineage_keys, edge.lineage_keys) then
          reason = "frozen-witness-generation-identity-mismatch"
        end

        if reason ~= nil then
          table.insert(unmapped, {
            owner = edge.owner,
            edge_id = edge.id,
            mode = generation.mode,
            reason = reason,
          })
        else
          table.insert(obligations, {
            obligation_id = edge.id .. "/generation",
            owner = edge.owner,
            edge_id = edge.id,
            case_kind = "generation",
            input_fixture_id = witness.input_fixture_id,
            expected_decision = witness.expected_decision,
            expected_effect_ids = witness.expected_effect_ids,
            expected_payload_obligations = witness.expected_payload_obligations,
            witness_id = witness.witness_id,
          })
        end
      end
    end

    define(obligations)
    return { obligations = obligations, unmapped = unmapped }
  end

  return K
end

return M
