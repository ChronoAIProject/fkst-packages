local core = require("core")
local restart_effect_seal = require("devloop.restart_effect_seal")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")

local owner = core.restart_package_name
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local edges = owner_pending_projection.edges(
  owner,
  core.restart_transition_table(),
  inventories
)

return restart_effect_seal.make({
  owner = owner,
  restart_authority = require("core.restart_authority"),
  edges = edges,
  sinks = require("core.restart.sink_inventory"),
})
