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

return M
