local core = require("core")
local dependency_gate = require("devloop.dependency_gate")

return {
  dependency_cycle_marker = function(...) return core.dependency_cycle_marker(...) end,
  dependency_gate = function(...) return core.dependency_gate(...) end,
  dependency_gate_has_notes = function(...) return core.dependency_gate_has_notes(...) end,
  dependency_gate_is_satisfied = dependency_gate.dependency_gate_is_satisfied,
  dependency_hold_fact = function(...) return core.dependency_hold_fact(...) end,
  dependency_unresolvable_marker = function(...) return core.dependency_unresolvable_marker(...) end,
  dependency_wait_marker = function(...) return core.dependency_wait_marker(...) end,
  restart_effect_facade = require("core.restart_effect_facade"),
  restart_effects = require("core.restart_effects"),
  restart_package_name = assert(rawget(core, "restart_package_name")),
  sink_inventory = require("core.restart.sink_inventory"),
}
