local W = {}
local devloop_prompts = require("devloop.prompts")

function W.prompts()
  return devloop_prompts.new({
    prompts = {
      decompose = require("prompts.decompose"),
    },
  }, { decompose = true })
end

return W
