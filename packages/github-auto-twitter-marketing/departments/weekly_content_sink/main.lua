local saga = require("workflow.saga")

local spec = {
  consumes = { "weekly_content_imported" },
  produces = {},
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event and event.payload or {}
  log.info("github-auto-twitter-marketing dept=weekly_content_sink tag=ACK artifact_id="
    .. tostring(payload.artifact_id))
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "weekly_content_sink",
})
