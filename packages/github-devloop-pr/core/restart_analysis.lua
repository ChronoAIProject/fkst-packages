local core = require("core")
local restart_transition_anomaly = require("devloop.restart_transition_anomaly")

local owner = core.restart_package_name
local canonical_rows = core.restart_transition_table()

local M = {}

function M.analyze_observed_transition_history(marker_history, observed_evidence)
  local owner_evidence = {}
  if type(observed_evidence) == "table" then
    for key, value in pairs(observed_evidence) do
      owner_evidence[key] = value
    end
  else
    owner_evidence.transitions = observed_evidence
  end
  owner_evidence.owner = owner
  return restart_transition_anomaly.analyze_observed_transition_history(
    canonical_rows,
    marker_history,
    owner_evidence
  )
end

return M
