local S = {}
local devloop_liveness = require("devloop.liveness")

function S.install(M)
local stall_suspect_threshold_minutes = {
  thinking = 30,
  ready = 30,
  implementing = 90,
  ["pr-open"] = 30,
  reviewing = 60,
  fixing = 90,
  merging = 30,
}

M.stall_suspect_age_minutes = devloop_liveness.stall_suspect_age_minutes

function M.stall_suspect_threshold_minutes(state)
  return stall_suspect_threshold_minutes[state]
end

end

return S
