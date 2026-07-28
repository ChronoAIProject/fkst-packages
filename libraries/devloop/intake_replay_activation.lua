local base_ids = require("devloop.base_ids")

local A = {
  target_queue = "github-devloop-intake.devloop_intake_candidate",
  target_dept = "github-devloop-intake-default.intake_judge",
}

local function source_ref_value(source_ref)
  if type(source_ref) ~= "table" then
    return nil
  end
  return source_ref.ref or source_ref.reference
end

local function source_ref_equal(left, right)
  return type(left) == "table"
    and type(right) == "table"
    and left.kind == right.kind
    and source_ref_value(left) == source_ref_value(right)
end

local function has_truncated_delivery_facts(snapshot)
  local truncated = snapshot and snapshot.truncated
  if type(truncated) ~= "table" then
    return true
  end
  return truncated.deliveries ~= false or truncated.dead_letters ~= false
end

function A.validate_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return nil, "observe-unavailable"
  end
  if type(snapshot.deliveries) ~= "table" or type(snapshot.dead_letters) ~= "table" then
    return nil, "observe-missing-delivery-facts"
  end
  if has_truncated_delivery_facts(snapshot) then
    return nil, "observe-truncated"
  end
  return snapshot, nil
end

function A.read_observe_snapshot()
  if type(fkst) ~= "table" or type(fkst.observe) ~= "function" then
    return nil, "observe-unavailable"
  end
  local ok, snapshot = pcall(function()
    return fkst.observe({ limit = 10000 })
  end)
  if not ok then
    return nil, "observe-unavailable:" .. tostring(snapshot)
  end
  return A.validate_snapshot(snapshot)
end

function A.matches_lineage(row, source_ref)
  return type(row) == "table"
    and row.queue == A.target_queue
    and row.dept == A.target_dept
    and source_ref_equal(row.source, source_ref)
end

function A.matching_live_delivery(snapshot, source_ref)
  for _, row in ipairs(snapshot.deliveries or {}) do
    if A.matches_lineage(row, source_ref) then
      return row
    end
  end
  return nil
end

function A.is_terminal_tombstone(row, source_ref)
  return A.matches_lineage(row, source_ref)
    and type(row.delivery_id) == "string"
    and row.delivery_id ~= ""
    and tonumber(row.attempts) ~= nil
    and tonumber(row.attempts) >= 1
    and row.permanent == true
    and row.replayable == false
end

function A.latest_terminal_tombstone(snapshot, source_ref)
  local selected = nil
  for _, row in ipairs(snapshot.dead_letters or {}) do
    if A.is_terminal_tombstone(row, source_ref) then
      if selected == nil or tonumber(row.dead_at_ms or 0) >= tonumber(selected.dead_at_ms or 0) then
        selected = row
      end
    end
  end
  return selected
end

function A.terminal_precondition(snapshot, source_ref)
  local validated, reason = A.validate_snapshot(snapshot)
  if validated == nil then
    return nil, reason
  end
  local normalized = base_ids.normalize_source_ref(source_ref)
  if A.matching_live_delivery(validated, normalized) ~= nil then
    return nil, "live-delivery-present"
  end
  local terminal = A.latest_terminal_tombstone(validated, normalized)
  if terminal == nil then
    return nil, "terminal-dlq-absent"
  end
  return terminal, nil
end

function A.observation_key(snapshot, source_ref)
  local validated, reason = A.validate_snapshot(snapshot)
  if validated == nil then
    return nil, reason
  end
  local normalized = base_ids.normalize_source_ref(source_ref)
  local terminal = A.latest_terminal_tombstone(validated, normalized)
  local parts = {
    "intake-replay-observation",
    tostring(normalized.kind),
    tostring(normalized.ref),
  }
  if terminal == nil then
    table.insert(parts, "terminal-absent")
  else
    table.insert(parts, "terminal")
    table.insert(parts, tostring(terminal.delivery_id))
    table.insert(parts, "attempts")
    table.insert(parts, tostring(terminal.attempts))
  end
  table.insert(parts, A.matching_live_delivery(validated, normalized) == nil and "inactive" or "live-present")
  return base_ids.dedup_key(parts), nil
end

return A
