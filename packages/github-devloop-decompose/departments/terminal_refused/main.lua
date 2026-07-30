local saga = require("workflow.saga")
local terminal_guard = require("devloop.terminal_guard")
local devloop_logging = require("devloop.logging")

local spec = {
  consumes = { "devloop_terminal_refused" },
  produces = {},
  stall_window = "30s",
  retry = false,
}

local function accepted(event)
  local payload = event and event.payload
  return terminal_guard.is_supported_refusal(payload)
    and payload.origin == "decompose"
end

local function act(event)
  local refusal = event.payload
  devloop_logging.log_cas_decision(
    "terminal_refused",
    refusal.proposal_id,
    {
      state = refusal.current_state,
      version = refusal.current_version,
    },
    "blocked",
    "reviewing",
    "observed(" .. tostring(refusal.reason) .. ")",
    "terminal refusal is published for an owning workflow to re-drive"
  )
end

return saga.department(spec, {
  accept = accepted,
  done = function() return false end,
  act = act,
  wrap = devloop_logging.wrap_pipeline_failure,
  name = "terminal_refused",
})
