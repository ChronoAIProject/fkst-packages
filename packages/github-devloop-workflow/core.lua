local blueprint = require("core.blueprint")
local catalog = require("core.catalog")
local digest = require("core.digest")
local marker = require("core.marker")
local select_request = require("core.select_request")
local devloop_base = require("devloop.base")

local M = {
  blueprint = blueprint,
  catalog = catalog,
  digest = digest,
  marker = marker,
}

M._max_dedup_len = devloop_base._max_dedup_len
M._max_meta_reason_len = devloop_base._max_meta_reason_len
M._test_bot_login = devloop_base._test_bot_login

function M.conformance_errors()
  -- TEMPORARY: increment 1 has no department; increment 2 must replace this
  -- with real saga conformance once the first department exists.
  return {}
end

function M.install(target)
  blueprint.install(target)
  catalog.install(target)
  digest.install(target)
  marker.install(target)
  select_request.install(target)
end

M.install(M)

return M
