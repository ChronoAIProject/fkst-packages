local M = {}

local function index_sinks(sink_inventory)
  local by_id = {}
  for _, sink in ipairs(sink_inventory) do
    by_id[sink.id] = sink
  end
  return by_id
end

function M.make(config)
  assert(type(config) == "table", "restart-effect-facade: config is required")
  assert(type(config.verify_grant) == "function",
    "restart-effect-facade: verify_grant must be a function")
  assert(type(config.sink_inventory) == "table",
    "restart-effect-facade: sink_inventory must be a table")
  assert(type(config.serializers) == "table",
    "restart-effect-facade: serializers must be a table")

  local verify_grant = config.verify_grant
  local sinks_by_id = index_sinks(config.sink_inventory)
  local serializers = config.serializers

  for effect_id, serializer in pairs(serializers) do
    assert(type(serializer) == "table" and type(serializer.sink_id) == "string"
      and type(serializer.serialize) == "function",
      "restart-effect-facade: invalid serializer for " .. tostring(effect_id))
    local sink = sinks_by_id[serializer.sink_id]
    assert(sink ~= nil,
      "restart-effect-facade: missing sink inventory record for " .. serializer.sink_id)
    assert(sink.authority_class == "lifecycle-authoritative",
      "restart-effect-facade: non-authoritative sink for " .. effect_id)
  end

  local facade = {}

  local function rejected_effect_reason(effect_id)
    local sink = sinks_by_id[effect_id] or sinks_by_id["queue:" .. tostring(effect_id)]
    if sink ~= nil and sink.authority_class ~= "lifecycle-authoritative" then
      return "not-lifecycle-authoritative"
    end
    return "unsupported-effect-id"
  end

  function facade.emit(grant, effect_id, sealed_snapshot, args)
    local serializer = serializers[effect_id]
    if serializer == nil then
      return nil, rejected_effect_reason(effect_id)
    end

    local sink = sinks_by_id[serializer.sink_id]
    if sink == nil or sink.authority_class ~= "lifecycle-authoritative" then
      return nil, "not-lifecycle-authoritative"
    end
    if verify_grant(grant, effect_id, sealed_snapshot) ~= true then
      return nil, "invalid-grant"
    end
    return serializer.serialize(args)
  end

  return facade
end

return M
