local M = {}

local function require_devloop_function(devloop, name)
  local value = devloop[name]
  if type(value) ~= "function" then
    error("devloop.adapters.workflow_ports: workflow-port-missing: missing " .. tostring(name))
  end
  return value
end

function M.from_devloop(devloop)
  if type(devloop) ~= "table" then
    error("devloop.adapters.workflow_ports: devloop-table-missing: missing devloop table")
  end
  local trusted_bot_login = require("devloop.base").trusted_bot_login
  local ports = {
    dependency_release_marker = function(...)
      return require_devloop_function(devloop, "dependency_release_marker")(...)
    end,
    restart_transition_table = function(...)
      return require_devloop_function(devloop, "restart_transition_table")(...)
    end,
    trusted_bot_login = function(...)
      return trusted_bot_login(...)
    end,
  }
  if devloop.actionable_epoch_resolve ~= nil then
    require_devloop_function(devloop, "actionable_epoch_resolve")
    ports.actionable_epoch_resolve = function(...)
      return require_devloop_function(devloop, "actionable_epoch_resolve")(...)
    end
  end
  if devloop.restart_durable_marker_fields ~= nil then
    require_devloop_function(devloop, "restart_durable_marker_fields")
    ports.restart_durable_marker_fields = function(...)
      return require_devloop_function(devloop, "restart_durable_marker_fields")(...)
    end
  end
  return ports
end

return M
