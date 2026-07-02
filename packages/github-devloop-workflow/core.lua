local blueprint = require("core.blueprint")
local catalog = require("core.catalog")

local M = {
  blueprint = blueprint,
  catalog = catalog,
}

function M.conformance_errors()
  -- TEMPORARY: increment 1 has no department; increment 2 must replace this
  -- with real saga conformance once the first department exists.
  return {}
end

function M.install(target)
  blueprint.install(target)
  catalog.install(target)
end

M.install(M)

return M
