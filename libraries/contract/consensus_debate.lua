local M = {}

local debate_phases = { "blind", "rebuttal", "synthesis" }

function M.debate_phase_names()
  return { debate_phases[1], debate_phases[2], debate_phases[3] }
end

return M
