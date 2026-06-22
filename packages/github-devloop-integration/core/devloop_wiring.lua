local W = {}

function W.prompts()
  return {
    prompts = {
      ["prompts.sync_conflict"] = require("prompts.sync_conflict"),
    },
  }
end

return W
