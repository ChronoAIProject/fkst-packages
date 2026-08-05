local temporal = require("devloop.restart_temporal_obligations")

local I = {}

function I.derive(rows)
  return temporal.derive_temporal_index(
    "github-devloop",
    rows,
    temporal.provider_capability_matrix()
  )
end

return I
