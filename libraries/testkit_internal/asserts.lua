local t = fkst.test

local M = {}

-- Deep structural equality with an exact-arity check at every level, so an extra key in
-- `actual` fails rather than passing unnoticed. Nine suites each carried this definition.
function M.assert_same_value(actual, expected)
  if type(expected) ~= "table" then
    t.eq(actual, expected)
    return
  end
  t.eq(type(actual), "table")
  local actual_count = 0
  for _ in pairs(actual) do
    actual_count = actual_count + 1
  end
  local expected_count = 0
  for key, nested in pairs(expected) do
    expected_count = expected_count + 1
    M.assert_same_value(actual[key], nested)
  end
  t.eq(actual_count, expected_count)
end

-- Asserts `value` has exactly the keys `expected` marks true. Seven suites each carried it.
function M.assert_exact_keys(value, expected)
  local count = 0
  for key in pairs(value) do
    count = count + 1
    t.eq(expected[key], true)
  end
  local expected_count = 0
  for _ in pairs(expected) do
    expected_count = expected_count + 1
  end
  t.eq(count, expected_count)
end

-- Returns an assert_valid_cas bound to the CAS catalog: an edge naming a cas_policy_id must
-- resolve in the catalog, and a named variant must exist on that definition. Four conformance
-- suites carried this. The catalog is injected because this library may depend only on
-- contract, workflow and forge, while restart_cas_catalog lives in devloop.
function M.bind_assert_valid_cas(restart_cas_catalog)
  return function(edge)
    if edge.cas_policy_id == nil then
      return
    end
    local definition = restart_cas_catalog.definition(edge.cas_policy_id)
    t.is_true(definition ~= nil)
    if edge.cas_variant ~= nil then
      t.is_true(definition.variants ~= nil)
      t.is_true(definition.variants[edge.cas_variant] ~= nil)
    end
  end
end

return M
