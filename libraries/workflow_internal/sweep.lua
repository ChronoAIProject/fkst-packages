-- contract.sweep: pure leaf utilities (bounds, rotation offset, cursor batching,
-- deferred-result shapes) shared across packages. Only genuine leaves live here:
-- functions whose original package bodies contained no late-bound `M.*`
-- call into another facade function. The `rotate`/`batch` orchestrators stay in
-- the package facade so their `M.sweep_rotate -> M.sweep_rotation_offset` and
-- `M.sweep_batch -> M.sweep_rotate` late-binding remains byte-for-byte observable.
local S = {}
local strings = require("contract.strings")
local decimal_checksum = strings.decimal_checksum

function S.positive_integer(value, fallback, minimum, maximum)
  local n = tonumber(value)
  if n == nil or n ~= math.floor(n) or n < minimum or n > maximum then
    return fallback
  end
  return n
end

function S.rotation_offset(count, seed)
  local n = tonumber(count)
  if n == nil or n <= 0 then
    return 0
  end
  local numeric_seed = tonumber(seed)
  if numeric_seed ~= nil and numeric_seed == math.floor(numeric_seed) then
    return numeric_seed % n
  end
  local hash = decimal_checksum(tostring(seed or ""))
  return tonumber(hash) % n
end

local function numeric_cursor_key(item, key_of)
  local value = type(key_of) == "function" and key_of(item) or item
  local key = tonumber(value)
  if key == nil or key < 0 or key ~= math.floor(key) then
    error("workflow_internal.sweep: cursor key must be a non-negative integer")
  end
  return key
end

function S.cursor_batch(items, cursor, cap, default_cap, key_of)
  local source = items or {}
  local count = #source
  local bounded_cap = S.positive_integer(cap, default_cap or 25, 1, 1000)
  if count == 0 then
    return {}, 0, 0
  end

  local cursor_key = tonumber(cursor)
  if cursor_key == nil or cursor_key < 0 or cursor_key ~= math.floor(cursor_key) then
    cursor_key = nil
  end

  local start = 1
  if cursor_key ~= nil then
    local found = false
    for index, item in ipairs(source) do
      if numeric_cursor_key(item, key_of) > cursor_key then
        start = index
        found = true
        break
      end
    end
    if not found then
      start = 1
    end
  end

  local selected = {}
  for i = 1, math.min(count, bounded_cap) do
    local index = ((start + i - 2) % count) + 1
    table.insert(selected, source[index])
  end

  local next_cursor = numeric_cursor_key(selected[#selected], key_of)
  return selected, math.max(0, count - #selected), next_cursor
end

function S.cursor_advance(items, processed, key_of)
  local source = items or {}
  local step = tonumber(processed) or 0
  if step < 0 or step ~= math.floor(step) then
    step = 0
  end
  step = math.min(step, #source)
  if step == 0 then
    return nil
  end
  return numeric_cursor_key(source[step], key_of)
end

function S.deadline_deferred_result(error_class, stderr)
  return {
    deferred = true,
    reason = "deadline",
    error_class = tostring(error_class or "sweep command"),
    stdout = "",
    stderr = tostring(stderr or "sweep deadline exhausted"),
    exit_code = 0,
  }
end

function S.result_deferred(result)
  return type(result) == "table" and result.deferred == true
end

return S
