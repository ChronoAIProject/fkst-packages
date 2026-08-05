local t = fkst.test
local H = {}

function H.run(proposal, opts)
  local result = t.run_department("departments/test_reach/main.lua", {
    queue = "test_reach",
    payload = proposal,
  }, opts)
  for _, raised in ipairs(result.raises or {}) do
    if tostring(raised.queue):match("test_reached$") then
      raised.queue = "consensus_reached"
    elseif tostring(raised.queue):match("test_converge$") then
      raised.queue = "consensus_converge"
    end
  end
  return result
end

return H
