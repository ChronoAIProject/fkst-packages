local consensus = require("consensus")
local saga = require("workflow.saga")

local spec = {
  consumes = { "test_reach" },
  produces = { "test_reached", "test_converge" },
  published_seam = { "test_reach" },
  ephemeral = { "test_reach" },
}

local function act(event)
  local proposal = event.payload or {}
  local result = consensus.reach(proposal)
  if result == nil then
    return
  end

  local payload = {}
  for key, value in pairs(result) do
    if key ~= "status" then
      payload[key] = value
    end
  end
  payload.proposal_id = proposal.proposal_id
  raise(result.status == "reached" and "test_reached" or "test_converge", payload)
end

return saga.department(spec, {
  name = "test_reach",
  done = function(_event)
    return false
  end,
  act = act,
})
