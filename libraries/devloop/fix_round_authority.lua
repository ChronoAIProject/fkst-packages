local config = require("devloop.config")
local devloop_state = require("devloop.state")

local M = {}

local function next_fix_version(version, current_round)
  return tostring(version or "") .. "/fix/" .. tostring(current_round + 1)
end

function M.next_or_decompose(version)
  local current_version = tostring(version or "")
  local current_round = devloop_state.version_fix_round(current_version)
  if current_round >= config.max_fix_rounds() then
    return {
      kind = "decompose",
      version = current_version,
      round = current_round,
    }
  end
  local next_version = next_fix_version(current_version, current_round)
  return {
    kind = "advance",
    version = next_version,
    round = devloop_state.version_fix_round(next_version),
  }
end

return M
