local C = {}

local seconds_per_minute = 60
local liveness_poll_interval_minutes = 5

function C.liveness_poll_interval()
  return tostring(liveness_poll_interval_minutes) .. "m"
end

function C.liveness_poll_cadence_seconds()
  return liveness_poll_interval_minutes * seconds_per_minute
end

return C
