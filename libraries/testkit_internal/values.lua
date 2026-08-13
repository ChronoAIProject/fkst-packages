local M = {}

-- Deep-copies nested tables, sharing keys. Non-table values are returned as-is.
-- Thirteen byte-identical definitions of this existed across the restart conformance
-- suites; sharing keys rather than copying them is the behaviour those callers rely on.
function M.copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, nested in pairs(value) do
    out[key] = M.copy_value(nested)
  end
  return out
end

-- Deep-copies nested tables, copying KEYS as well as values. Distinct from copy_value,
-- which shares keys; eight suites each carried their own identical definition.
function M.copy_value_and_keys(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, nested in pairs(value) do
    out[M.copy_value_and_keys(key)] = M.copy_value_and_keys(nested)
  end
  return out
end

-- True when `values` contains `expected`. Eighteen definitions existed under four names.
-- Production sites keep their own: this is a test library, and production must not require it.
function M.has_value(values, expected)
  for _, value in ipairs(values or {}) do
    if value == expected then
      return true
    end
  end
  return false
end

-- The set of `keys` as a table mapping each to true. Seven suites carried this.
function M.key_set(keys)
  local out = {}
  for _, key in ipairs(keys) do
    out[key] = true
  end
  return out
end

-- Indexes restart rows by their from_state. Eight suites carried this under two names.
-- The production copy in libraries/devloop keeps its own: it additionally guards against nil
-- rows and nil from_state, and production must not require a test library regardless.
function M.rows_by_state(rows)
  local by_state = {}
  for _, row in ipairs(rows or {}) do
    by_state[row.from_state] = row
  end
  return by_state
end

return M
