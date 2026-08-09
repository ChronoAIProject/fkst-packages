local W = {}
local default_intake = require("devloop.intake.default")
local devloop_prompts = require("devloop.prompts")
W.prompt = default_intake.prompt

function W.prompts()
  return devloop_prompts.new({
    prompts = {
      intake = default_intake.prompt,
    },
  }, {
    intake = true,
    intake_parser = true,
  })
end

return W
