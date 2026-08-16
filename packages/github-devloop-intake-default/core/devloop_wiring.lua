local W = {}
local default_intake = require("devloop.intake.default")
W.prompt = default_intake.prompt

function W.prompts()
  return default_intake.prompt_surface()
end

return W
