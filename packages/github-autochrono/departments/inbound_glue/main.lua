local core = require("core")
local saga = require("std.saga")

local spec = {
  consumes = { "github-proxy.github_entity_changed" },
  produces = { "autochrono.issue" },
  fanout = { "github-proxy.github_entity_changed" },
  stall_window = "30s",
}

local function recurring_delivery(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  if payload.type ~= "issue" then
    return
  end

  raise("autochrono.issue", core.entity_to_issue(payload))
end

return saga.department{
  consumes = spec.consumes,
  produces = spec.produces,
  fanout = spec.fanout,
  stall_window = spec.stall_window,
  retry = spec.retry,
  ephemeral = spec.ephemeral,
  done = recurring_delivery,
  act = act,
  name = "inbound_glue",
}
