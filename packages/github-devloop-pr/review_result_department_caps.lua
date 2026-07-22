local core = require("core")

return {
  restart_effect_facade = require("core.restart_effect_facade"),
  restart_effects = require("core.restart_effects"),
  restart_package_name = assert(rawget(core, "restart_package_name")),
  sink_inventory = require("core.restart.sink_inventory"),
}
