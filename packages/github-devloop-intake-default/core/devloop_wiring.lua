local W = {}

function W.prompts()
  return {
    prompts = {
      intake = require("devloop.intake.prompt"),
    },
  }
end

return W
