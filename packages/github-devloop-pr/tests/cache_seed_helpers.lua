local saga = require("workflow.saga")

local spec = {
  consumes = { "test_cache_seed" },
  produces = {},
  ephemeral = { "test_cache_seed" },
  retry = false,
}

return saga.department(spec, {
  name = "test_cache_seed",
  done = function(_event)
    return false
  end,
  act = function(event)
    local payload = event.payload or {}
    cache_set(payload.key, payload.value)
  end,
})
