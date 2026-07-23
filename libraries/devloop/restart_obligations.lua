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

return M
