local core = require("core")

return {
  dependency_hold_fact = function(...) return core.dependency_hold_fact(...) end,
  dependency_waiver_marker = core.dependency_waiver_marker,
  restart_policy = assert(rawget(core, "restart_policy")),
  restart_effect_facade = require("core.restart_effect_facade"),
  restart_effects = require("core.restart_effects"),
  restart_package_name = assert(rawget(core, "restart_package_name")),
  sink_inventory = require("core.restart.sink_inventory"),
}
