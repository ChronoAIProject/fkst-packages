local saga = require("std.saga")

local spec = {
  consumes = { "github_entity_changed_request" },
  published_seam = { "github_entity_changed_request" },
  produces = { "github_entity_changed" },
  stall_window = "30s",
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local changed = payload.payload
  if type(changed) ~= "table" then
    error("github-proxy: entity-changed-request-missing-payload: request payload is missing")
  end
  raise("github_entity_changed", changed)
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "github_entity_changed_request",
})
