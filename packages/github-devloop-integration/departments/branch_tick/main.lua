local branch_tick = require("branch_tick")
local saga = require("workflow.saga")

local spec = {
  consumes = { branch_tick.source_queue },
  produces = { branch_tick.target_queue },
  retry = {},
  stall_window = "30s",
}

-- A stable raised dedup_key selects the delivery store's first-record-wins
-- identity. The identity includes the subscriber department, so this is a
-- subscriber-scoped Forbid contract: queued or in-flight overlaps are dropped,
-- and branch_poll offers a fresh activation within poll_interval after ack.
local function act(_event)
  raise(branch_tick.target_queue, branch_tick.payload())
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  name = "branch_tick",
})
