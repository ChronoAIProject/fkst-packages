local sha256 = require("contract.sha256")
local core = require("core")
local nil_if_json_null = core.nil_if_json_null

local R = {}

local function base_generation_index()
  return {
    key_for = function(_queue, base_key)
      return base_key
    end,
  }
end

local function snapshot_is_truncated(snapshot)
  local truncated = type(snapshot) == "table" and snapshot.truncated or nil
  return type(truncated) == "table"
    and (
      truncated.deliveries == true
      or truncated.dead_letters == true
      or truncated.terminal_suppressions == true
    )
end

local function require_complete_snapshot(snapshot)
  if type(snapshot) ~= "table"
    or type(snapshot.deliveries) ~= "table"
    or type(snapshot.dead_letters) ~= "table" then
    error("github-proxy: delivery-rearm-observe-malformed: delivery snapshot is missing required sections")
  end
  local terminal_suppressions = nil_if_json_null(snapshot.terminal_suppressions)
  if terminal_suppressions ~= nil and type(terminal_suppressions) ~= "table" then
    error("github-proxy: delivery-rearm-observe-malformed: delivery snapshot has invalid terminal_suppressions section type")
  end
  local truncated = snapshot.truncated
  if type(truncated) ~= "table"
    or truncated.deliveries ~= false
    or truncated.dead_letters ~= false
    or (terminal_suppressions ~= nil and truncated.terminal_suppressions ~= false) then
    error("github-proxy: delivery-rearm-observe-truncated: complete delivery facts are required")
  end
  if terminal_suppressions == nil then
    log.warn(
      "github-proxy: delivery-rearm-observe-legacy: engine predates terminal_suppressions; treating suppression facts as empty"
    )
    return {}
  end
  return terminal_suppressions
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

local function entry_for(entries, queue, dept, dedup_key)
  local by_queue = entries[queue]
  if by_queue == nil then
    by_queue = {}
    entries[queue] = by_queue
  end
  local root = lineage_key(dedup_key)
  local by_subscriber = by_queue[root]
  if by_subscriber == nil then
    by_subscriber = {}
    by_queue[root] = by_subscriber
  end
  local subscriber = tostring(dept or "")
  local entry = by_subscriber[subscriber]
  if entry == nil then
    entry = {}
    by_subscriber[subscriber] = entry
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
  local entry = entry_for(entries, queue, row.dept, dedup_key)
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
  if lineage_key(dedup_key) ~= dedup_key and (entry.outstanding_rearm_key == nil or newer(
    row.observed_at_ms,
    row.delivery_id,
    entry.outstanding_rearm_at_ms,
    entry.outstanding_rearm_id
  )) then
    entry.outstanding_rearm_key = dedup_key
    entry.outstanding_rearm_at_ms = row.observed_at_ms
    entry.outstanding_rearm_id = row.delivery_id
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
  local entry = entry_for(entries, queue, row.dept, dedup_key)
  if entry.terminal_id == nil or newer(
    row.dead_at_ms,
    row.delivery_id,
    entry.terminal_at_ms,
    entry.terminal_id
  ) then
    entry.terminal_id = tostring(row.delivery_id)
    entry.terminal_key = dedup_key
    entry.terminal_at_ms = row.dead_at_ms
  end
end

local function record_terminal_suppression(entries, row, allowed)
  local queue = tostring(row.queue or "")
  if queue == "" or (allowed ~= nil and allowed[queue] ~= true) then
    return
  end
  local dedup_key = row.dedup_key
  if type(dedup_key) ~= "string" or dedup_key == "" then
    return
  end
  local entry = entry_for(entries, queue, row.dept, dedup_key)
  if entry.terminal_id == nil or newer(
    row.terminal_at_ms,
    row.delivery_id,
    entry.terminal_at_ms,
    entry.terminal_id
  ) then
    entry.terminal_id = tostring(row.delivery_id)
    entry.terminal_key = dedup_key
    entry.terminal_at_ms = row.terminal_at_ms
  end
end

function R.index(snapshot, queues)
  local terminal_suppressions = require_complete_snapshot(snapshot)
  local entries = {}
  local allowed = selected_queues(queues)
  for _, row in ipairs(snapshot.deliveries) do
    record_outstanding(entries, row, allowed)
  end
  for _, row in ipairs(snapshot.dead_letters) do
    record_terminal(entries, row, allowed)
  end
  for _, row in ipairs(terminal_suppressions) do
    record_terminal_suppression(entries, row, allowed)
  end

  return {
    key_for = function(queue, base_key)
      local by_queue = entries[tostring(queue)] or {}
      local by_subscriber = by_queue[tostring(base_key)]
      if by_subscriber == nil then
        return base_key
      end
      local outstanding_key = nil
      local outstanding_at_ms = nil
      local outstanding_id = nil
      local outstanding_rearm_key = nil
      local outstanding_rearm_at_ms = nil
      local outstanding_rearm_id = nil
      local terminal_id = nil
      local terminal_key = nil
      local terminal_at_ms = nil
      for _, entry in pairs(by_subscriber) do
        if entry.outstanding_key ~= nil and (outstanding_key == nil or newer(
          entry.outstanding_at_ms,
          entry.outstanding_id,
          outstanding_at_ms,
          outstanding_id
        )) then
          outstanding_key = entry.outstanding_key
          outstanding_at_ms = entry.outstanding_at_ms
          outstanding_id = entry.outstanding_id
        end
        if entry.outstanding_rearm_key ~= nil and (outstanding_rearm_key == nil or newer(
          entry.outstanding_rearm_at_ms,
          entry.outstanding_rearm_id,
          outstanding_rearm_at_ms,
          outstanding_rearm_id
        )) then
          outstanding_rearm_key = entry.outstanding_rearm_key
          outstanding_rearm_at_ms = entry.outstanding_rearm_at_ms
          outstanding_rearm_id = entry.outstanding_rearm_id
        end
        if entry.terminal_id ~= nil and (terminal_id == nil or newer(
          entry.terminal_at_ms,
          entry.terminal_id,
          terminal_at_ms,
          terminal_id
        )) then
          terminal_id = entry.terminal_id
          terminal_key = entry.terminal_key
          terminal_at_ms = entry.terminal_at_ms
        end
      end
      -- A rearm generation fans out to every subscriber, so keep it as the
      -- queue-wide outstanding generation until all subscriber copies drain.
      if outstanding_rearm_key ~= nil then
        return outstanding_rearm_key
      end
      -- Do not mint another queue-wide generation while an earlier generation
      -- is still live after a rearm delivery becomes terminal.
      if terminal_key ~= nil
        and lineage_key(terminal_key) ~= terminal_key
        and outstanding_key ~= nil then
        return outstanding_key
      end
      if terminal_id ~= nil then
        return tostring(base_key) .. "/rearm/" .. sha256.hex(terminal_id)
      end
      if outstanding_key ~= nil then
        return outstanding_key
      end
      return base_key
    end,
  }
end

function R.current(queues)
  if type(fkst) ~= "table" or type(fkst.observe) ~= "function" then
    error("github-proxy: delivery-rearm-observe-unavailable: fkst.observe is unavailable")
  end
  local snapshot = fkst.observe({ limit = 10000 })
  if snapshot_is_truncated(snapshot) then
    log.warn(
      "github-proxy: delivery-rearm-observe-truncated: delivery snapshot truncated; falling back to base generation"
    )
    return base_generation_index()
  end
  return R.index(snapshot, queues)
end

return R
