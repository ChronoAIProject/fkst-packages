local blueprint = require("core.blueprint")
local catalog = require("core.catalog")
local digest = require("core.digest")
local marker = require("core.marker")
local select_request = require("core.select_request")
local devloop_base = require("devloop.base")
local intake_install = require("devloop.intake.install")
local saga_conformance = require("devloop.saga_conformance")

local M

local function conformance_errors()
  return saga_conformance.errors(M)
end

M = {
  blueprint = blueprint,
  catalog = catalog,
  digest = digest,
  marker = marker,
  conformance_errors = conformance_errors,
}

M._max_dedup_len = devloop_base._max_dedup_len
M._max_meta_reason_len = devloop_base._max_meta_reason_len
M._test_bot_login = devloop_base._test_bot_login

function M.install(target)
  blueprint.install(target)
  catalog.install(target)
  digest.install(target)
  marker.install(target)
  select_request.install(target)
  intake_install.install(target)
end

M.install(M)

return M
