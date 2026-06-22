local W = {}

function W.prompts()
  return {
    prompts = {
      ["prompts.decompose"] = require("prompts.decompose"),
    },
  }
end

return W
