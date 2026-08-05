local W = {}

function W.prompts()
  return {
    prompts = {
      decompose = require("prompts.decompose"),
      implementation_decompose = require("prompts.implementation_decompose"),
    },
  }
end

return W
