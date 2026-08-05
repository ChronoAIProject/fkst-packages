local core = require("core")

return {
  restart_effects = require("core.restart_effects"),
  restart_package_name = assert(rawget(core, "restart_package_name")),
}
