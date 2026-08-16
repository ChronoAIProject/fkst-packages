local testing = require("testkit_internal.testing")

local M = {}

function M.final_message(message)
  if type(message) ~= "string" then
    error("testkit-internal: codex-final-message-invalid: message must be a string")
  end
  local text = testing.escape_json_string(message, "\\u%04X")
  return '{"type":"item.completed","item":{"type":"agent_message","text":"' .. text .. '"}}\n'
end

return M
