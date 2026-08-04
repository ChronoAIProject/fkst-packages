-- Deterministic key ordering shared by the conformance modules.
--
-- Extracting `issue_observation_conformance` out of `span_conformance` copied this
-- helper into both, which G-DEDUP rejects: a byte-identical production function body
-- across files has no single owner. It lives here instead of in either conformance
-- module because it is a generic list utility, not conformance domain logic, and it
-- cannot live in `core.lua` -- that module requires `core.span_conformance`, so the
-- dependency would be circular.

local M = {}

function M.sorted_keys(map)
  local keys = {}
  for key, _ in pairs(map or {}) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

return M
