local M = {}

local observe_schema_version = 1

local function required_list(facts, name)
  local value = facts[name]
  if type(value) ~= "table" then
    error("archaudit: observe-malformed-facts: malformed " .. name)
  end
  local count = 0
  local max_index = 0
  for key, _item in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
      error("archaudit: observe-malformed-facts: malformed " .. name)
    end
    count = count + 1
    if key > max_index then
      max_index = key
    end
  end
  if max_index ~= count then
    error("archaudit: observe-malformed-facts: malformed " .. name)
  end
  return value
end

local function required_int(row, name)
  local value = row[name]
  if type(value) ~= "number" or value < 0 or math.floor(value) ~= value then
    error("archaudit: observe-malformed-metric: " .. tostring(name) .. " must be a non-negative integer")
  end
  return value
end

local function required_table(facts, name)
  local value = facts[name]
  if type(value) ~= "table" then
    error("archaudit: observe-malformed-facts: malformed " .. name)
  end
  return value
end

local function required_bool(row, name)
  local value = row[name]
  if type(value) ~= "boolean" then
    error("archaudit: observe-malformed-facts: " .. tostring(name) .. " must be a boolean")
  end
  return value
end

function M.validate_observe_facts(facts)
  if type(facts) ~= "table" then
    error("archaudit: observe-malformed-top-level: facts must be a table")
  end
  if facts.schema_version ~= observe_schema_version then
    error("archaudit: observe-unknown-schema-version: expected schema_version=1")
  end
  if type(facts.generated_at_ms) ~= "number" or facts.generated_at_ms < 0 or math.floor(facts.generated_at_ms) ~= facts.generated_at_ms then
    error("archaudit: observe-malformed-facts: generated_at_ms must be a non-negative integer")
  end
  required_table(facts, "source")
  local limits = required_table(facts, "limits")
  required_int(limits, "max_deliveries")
  required_int(limits, "max_dead_letters")
  local truncated = required_table(facts, "truncated")
  required_bool(truncated, "deliveries")
  required_bool(truncated, "dead_letters")
  required_list(facts, "queues")
  required_list(facts, "deliveries")
  required_list(facts, "dead_letters")
  for _, row in ipairs(facts.queues) do
    if type(row) ~= "table" then
      error("archaudit: observe-malformed-queue-row: queue row must be a table")
    end
    if type(row.queue) ~= "string" or row.queue == "" then
      error("archaudit: observe-malformed-queue-name: queue name must be non-empty")
    end
    required_int(row, "depth")
    required_int(row, "pending")
    required_int(row, "in_flight")
    required_int(row, "retrying")
  end
  return facts
end

function M.observe_now_seconds(facts)
  M.validate_observe_facts(facts)
  return math.floor(facts.generated_at_ms / 1000)
end

function M.is_idle_observe(facts)
  M.validate_observe_facts(facts)
  if facts.truncated.deliveries then
    return false, "current observe truncated deliveries"
  end
  if facts.truncated.dead_letters then
    return false, "current observe truncated dead_letters"
  end
  for _, row in ipairs(facts.queues) do
    for _, field in ipairs({ "pending", "in_flight", "retrying", "depth" }) do
      if row[field] > 0 then
        return false, "current observe busy queue=" .. tostring(row.queue) .. " " .. field .. "=" .. tostring(row[field])
      end
    end
  end
  if #facts.deliveries > 0 then
    return false, "current observe deliveries=" .. tostring(#facts.deliveries)
  end
  if #facts.dead_letters > 0 then
    return false, "current observe dead_letters=" .. tostring(#facts.dead_letters)
  end
  return true, nil
end

function M.facts(opts)
  if type(fkst) ~= "table" or type(fkst.observe) ~= "function" then
    error("archaudit: missing-observe: fkst.observe is required")
  end
  local ok, facts = pcall(fkst.observe, opts)
  if not ok then
    local message = tostring(facts)
    if message:find("FKST_DURABLE_ROOT", 1, true) ~= nil then
      error("archaudit: observe-durable-root-unresolved: " .. message)
    end
    if message:find("fkst.observe snapshot", 1, true) ~= nil then
      error("archaudit: observe-malformed: " .. message)
    end
    error("archaudit: observe-unreadable: " .. message)
  end
  return M.validate_observe_facts(facts)
end

return M
