local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "devloop_doctor_tick" },
  produces = {},
  retry = false,
  stall_window = "2m",
}

local function not_done(_event)
  return false
end

local function act(_event)
  print(core.saga_doctor_run())
end

return saga.department{
  consumes = spec.consumes,
  produces = spec.produces,
  fanout = spec.fanout,
  stall_window = spec.stall_window,
  retry = spec.retry,
  ephemeral = spec.ephemeral,
  done = not_done,
  act = act,
  wrap = core.wrap_pipeline_failure,
  name = "doctor",
}
