local M = {}

local error_facts = require("std.error_facts")

local observe_schema = "fkst.observe.v1"

function M.persistence_class()
  return "stateless_adapter"
end

local function int_value(value)
  if type(value) == "number" then
    if value < 0 or math.floor(value) ~= value then
      error("idle-detector: malformed-observe-metric: value must be a non-negative integer")
    end
    return value
  end
  if type(value) == "string" and value:match("^%d+$") then
    return tonumber(value)
  end
  error("idle-detector: malformed-observe-metric: value must be a non-negative integer")
end

local function required_metric(row, names, group)
  local found = nil
  for _, name in ipairs(names) do
    if row[name] ~= nil then
      if found ~= nil then
        error("idle-detector: ambiguous-observe-metric: multiple fields in one metric group")
      end
      found = { value = int_value(row[name]), name = name }
    end
  end
  if found == nil then
    error("idle-detector: missing-observe-metric: missing metric group " .. tostring(group))
  end
  return found.value, found.name
end

local function required_list(facts, name)
  local value = facts[name]
  if type(value) ~= "table" then
    error("idle-detector: malformed-observe-facts: malformed " .. name)
  end
  return value
end

local function validate_observe_facts(facts)
  if type(facts) ~= "table" then
    error("idle-detector: malformed-observe-facts: top-level facts must be a table")
  end
  if facts.schema ~= observe_schema then
    error("idle-detector: unknown-observe-schema: expected fkst.observe.v1")
  end
  required_list(facts, "queues")
  required_list(facts, "anomalies")
  required_list(facts, "dlq")
  return facts
end

function M.observe(exec)
  local run = exec or exec_sync
  if type(run) ~= "function" then
    error("idle-detector: missing-exec: observe requires exec_sync")
  end
  local result = run({ cmd = "fkst-framework observe --json", timeout = 30 })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("idle-detector: observe-failed: " .. tostring(result and result.stderr or "no result"))
  end
  local ok, decoded = pcall(json.decode, result.stdout or "")
  if not ok or type(decoded) ~= "table" then
    error("idle-detector: malformed-observe-json: observe returned malformed JSON")
  end
  return validate_observe_facts(decoded)
end

function M.is_idle_observe(facts)
  validate_observe_facts(facts)
  for _, row in ipairs(facts.queues) do
    if type(row) ~= "table" then
      error("idle-detector: malformed-observe-row: queue row must be a table")
    end
    if type(row.queue) ~= "string" or row.queue == "" then
      error("idle-detector: malformed-observe-row: queue name must be non-empty")
    end
    local queue = row.queue
    local ready, ready_name = required_metric(row, { "ready", "pending", "due", "available", "depth" }, "ready")
    if ready > 0 then
      return false, "busy queue=" .. queue .. " " .. ready_name .. "=" .. tostring(ready)
    end
    local leased, leased_name = required_metric(row, { "leased", "inflight", "in_flight", "running", "active" }, "leased")
    if leased > 0 then
      return false, "busy queue=" .. queue .. " " .. leased_name .. "=" .. tostring(leased)
    end
    local retry, retry_name = required_metric(row, { "retry", "retries", "retry_pending", "delayed", "backoff" }, "retry")
    if retry > 0 then
      return false, "busy queue=" .. queue .. " " .. retry_name .. "=" .. tostring(retry)
    end
    local dlq, dlq_name = required_metric(row, { "dlq", "dead", "dead_letters", "dead_letter" }, "dlq")
    if dlq > 0 then
      return false, "busy queue=" .. queue .. " " .. dlq_name .. "=" .. tostring(dlq)
    end
  end
  if #facts.dlq > 0 then
    return false, "busy dlq>0"
  end
  if #facts.anomalies > 0 then
    return false, "busy anomaly>0"
  end
  return true, nil
end

function M.build_system_idle_payload(detected_at, observe_ref, expires_at)
  local payload = {
    schema = "idle-detector.system-idle.v1",
    detected_at = tostring(detected_at),
    source_ref = {
      kind = "host-observe",
      ref = tostring(observe_ref),
    },
  }
  if expires_at ~= nil then
    payload.expires_at = tostring(expires_at)
  end
  return payload
end

function M.iso_timestamp_epoch_seconds(timestamp)
  local year, month, day, hour, minute, second = tostring(timestamp or ""):match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
  )
  if year == nil then
    return nil
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  if month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59 then
    return nil
  end
  if month <= 2 then
    year = year - 1
    month = month + 12
  end
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local day_of_year = math.floor((153 * (month - 3) + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
  return (era * 146097 + day_of_era - 719468) * 86400 + hour * 3600 + minute * 60 + second
end

function M.freshness_verdict(reference_ts_seconds, now_seconds, budget_seconds)
  if type(reference_ts_seconds) ~= "number" or type(now_seconds) ~= "number" or type(budget_seconds) ~= "number" then
    error("idle-detector: malformed-freshness: timestamp inputs must be numeric")
  end
  if now_seconds - reference_ts_seconds > budget_seconds then
    return "stale"
  end
  return "fresh"
end

function M.skip_fact(dept, event, why, terminal)
  local fields = error_facts.error_fact_fields("terminal-skip", type(event) == "table" and event.queue or nil, dept, why, {
    source_ref = error_facts.event_source_ref(event),
    terminal = terminal,
  })
  table.insert(fields, "WHY=" .. error_facts.one_line(why))
  return "idle-detector dept=" .. tostring(dept) .. " tag=SKIP " .. table.concat(fields, " ")
end

return M
