local blueprint = require("core.blueprint")
local catalog = require("core.catalog")
local child_result = require("core.child_result")
local default_catalog = require("core.default_catalog")
local digest = require("core.digest")
local frontier = require("core.frontier")
local generator = require("core.generator")
local marker = require("core.marker")
local materialize_reconcile = require("core.materialize_reconcile")
local materialization = require("core.materialization")
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
  child_result = child_result,
  default_catalog = default_catalog,
  digest = digest,
  frontier = frontier,
  generator = generator,
  marker = marker,
  materialize_reconcile = materialize_reconcile,
  materialization = materialization,
  conformance_errors = conformance_errors,
}

M._max_dedup_len = devloop_base._max_dedup_len
M._max_meta_reason_len = devloop_base._max_meta_reason_len
M._test_bot_login = devloop_base._test_bot_login

function M.install(target)
  blueprint.install(target)
  catalog.install(target)
  child_result.install(target)
  default_catalog.install(target)
  digest.install(target)
  frontier.install(target)
  generator.install(target)
  marker.install(target)
  materialization.install(target)
  select_request.install(target)
  intake_install.install(target)
end

M.install(M)

return M
