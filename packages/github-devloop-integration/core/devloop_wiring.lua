local W = {}
local devloop_prompts = require("devloop.prompts")

function W.prompts()
  return devloop_prompts.new({
    prompts = {
      sync_conflict = require("prompts.sync_conflict"),
    },
  }, { sync_conflict = true })
end

return W
