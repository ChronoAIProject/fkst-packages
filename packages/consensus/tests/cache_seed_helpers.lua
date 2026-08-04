M = {}

M.spec = {
  consumes = { "cache_seed" },
  produces = { "cache_seeded" },
}

function pipeline(event)
  local payload = event.payload or {}
  if payload.value ~= nil then
    cache_set(payload.key, payload.value)
  end
  raise("cache_seeded", {
    key = payload.key,
    value = cache_get(payload.key),
  })
end

M.pipeline = pipeline

return M
