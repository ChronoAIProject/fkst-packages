local M = {}

M.spec = {
  consumes = { "cache_seed" },
}

function pipeline(event)
  local payload = event.payload or {}
  cache_set(payload.key, payload.value)
end

M.pipeline = pipeline

return M
