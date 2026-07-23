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

local kinds = require("devloop.restart_obligation_derivations").new({
  define = M.define,
  require_nonempty_string = require_nonempty_string,
  require_dense_string_array = require_dense_string_array,
})

M.derive_edge = kinds.derive_edge
M.derive = kinds.derive
M.derive_pending = kinds.derive_pending
M.derive_edge_pair = kinds.derive_edge_pair
M.derive_entitlement = kinds.derive_entitlement
M.derive_family_variant = kinds.derive_family_variant
M.derive_timeout = kinds.derive_timeout

return M
