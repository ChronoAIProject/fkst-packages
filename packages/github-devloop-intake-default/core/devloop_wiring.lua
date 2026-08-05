local W = {}
local default_intake = require("devloop.intake.default")

function W.prompts()
  return {
    prompts = {
      intake = default_intake.prompt,
    },
  }
end

return W
