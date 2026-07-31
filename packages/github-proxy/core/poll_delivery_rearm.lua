local sha256 = require("contract.sha256")

local R = {}

local function require_complete_snapshot(snapshot)
  if type(snapshot) ~= "table"
    or type(snapshot.deliveries) ~= "table"
    or type(snapshot.dead_letters) ~= "table" then
    error("github-proxy: delivery-rearm-observe-malformed: delivery snapshot is missing required sections")
  end
  local truncated = snapshot.truncated
  if type(truncated) ~= "table"
    or truncated.deliveries ~= false
    or truncated.dead_letters ~= false then
    error("github-proxy: delivery-rearm-observe-truncated: complete delivery facts are required")
  end
end

local function lineage_key(dedup_key)
  local root, generation = tostring(dedup_key or ""):match("^(.*)/rearm/([0-9a-f]+)$")
  if root ~= nil and #generation == 64 then
    return root
  end
  return tostring(dedup_key or "")
end

local function payload_dedup_key(row)
  local payload = type(row) == "table" and row.payload or nil
  if type(payload) ~= "table" or type(payload.dedup_key) ~= "string" then
    return nil
  end
  if payload.dedup_key == "" then
    return nil
  end
  return payload.dedup_key
end

local function selected_queues(queues)
  if queues == nil then
    return nil
  end
  local selected = {}
  for _, queue in ipairs(queues) do
    selected[tostring(queue)] = true
  end
  return selected
end

local function entry_for(entries, queue, dedup_key)
  local by_queue = entries[queue]
  if by_queue == nil then
    by_queue = {}
    entries[queue] = by_queue
  end
  local root = lineage_key(dedup_key)
  local entry = by_queue[root]
  if entry == nil then
    entry = {}
    by_queue[root] = entry
  end
  return entry
end

local function newer(candidate_at, candidate_id, current_at, current_id)
  local candidate_time = tonumber(candidate_at) or 0
  local current_time = tonumber(current_at) or 0
  if candidate_time ~= current_time then
    return candidate_time > current_time
  end
  return tostring(candidate_id or "") > tostring(current_id or "")
end

local function record_outstanding(entries, row, allowed)
  local queue = tostring(row.queue or "")
  if queue == "" or (allowed ~= nil and allowed[queue] ~= true) then
    return
  end
  local dedup_key = payload_dedup_key(row)
  if dedup_key == nil then
    return
  end
  local entry = entry_for(entries, queue, dedup_key)
  if entry.outstanding_key == nil or newer(
    row.observed_at_ms,
    row.delivery_id,
    entry.outstanding_at_ms,
    entry.outstanding_id
  ) then
    entry.outstanding_key = dedup_key
    entry.outstanding_at_ms = row.observed_at_ms
    entry.outstanding_id = row.delivery_id
  end
end

local function record_terminal(entries, row, allowed)
  local queue = tostring(row.queue or "")
  if queue == "" or (allowed ~= nil and allowed[queue] ~= true) then
    return
  end
  local dedup_key = payload_dedup_key(row)
  if dedup_key == nil then
    return
  end
  if row.permanent ~= true or row.replayable ~= false then
    record_outstanding(entries, row, allowed)
    return
  end
  local entry = entry_for(entries, queue, dedup_key)
  if entry.terminal_id == nil or newer(
    row.dead_at_ms,
    row.delivery_id,
    entry.terminal_at_ms,
    entry.terminal_id
  ) then
    entry.terminal_id = tostring(row.delivery_id)
    entry.terminal_at_ms = row.dead_at_ms
  end
end

function R.index(snapshot, queues)
  require_complete_snapshot(snapshot)
  local entries = {}
  local allowed = selected_queues(queues)
  for _, row in ipairs(snapshot.deliveries) do
    record_outstanding(entries, row, allowed)
  end
  for _, row in ipairs(snapshot.dead_letters) do
    record_terminal(entries, row, allowed)
  end

  return {
    key_for = function(queue, base_key)
      local by_queue = entries[tostring(queue)] or {}
      local entry = by_queue[tostring(base_key)]
      if entry == nil then
        return base_key
      end
      if entry.outstanding_key ~= nil then
        return entry.outstanding_key
      end
      if entry.terminal_id ~= nil then
        return tostring(base_key) .. "/rearm/" .. sha256.hex(entry.terminal_id)
      end
      return base_key
    end,
  }
end

function R.current(queues)
  if type(fkst) ~= "table" or type(fkst.observe) ~= "function" then
    error("github-proxy: delivery-rearm-observe-unavailable: fkst.observe is unavailable")
  end
  return R.index(fkst.observe({ limit = 10000 }), queues)
end

return R
