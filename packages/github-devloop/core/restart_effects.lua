local core = require("core")
local restart_effect_seal = require("devloop.restart_effect_seal")

local owner = core.restart_package_name
local restart_authority = require("core.restart_authority")
local edges = restart_authority.edges()

return restart_effect_seal.make({
  owner = owner,
  restart_authority = restart_authority,
  edges = edges,
  sinks = require("core.restart.sink_inventory"),
})
