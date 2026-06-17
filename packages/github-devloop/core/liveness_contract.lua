local S = {}

local known_liveness_contract_violations = {
  implementing = true,
  ready = true,
  reviewing = true,
  thinking = true,
}

local function append_error(errors, message, kind, state)
  table.insert(errors, {
    message = message,
    kind = kind,
    state = state,
  })
end

local function row_can_live_defer(row)
  return row
    and row.terminal == false
    and type(row.watchdog) == "table"
    and row.watchdog.mode == "live-defer"
end

local function is_known_live_defer_state_entry_violation(record)
  local message = tostring(record and record.message or "")
  return message:find("state_entry:v1 is only allowed when no defer is possible", 1, true) ~= nil
    or message:find("live-defer row actionable_epoch.source must exclude deferred time", 1, true) ~= nil
end

function S.known_violations()
  local states = {}
  for state, _ in pairs(known_liveness_contract_violations) do
    table.insert(states, state)
  end
  table.sort(states)
  return states
end

function S.validate_registry(M, errors)
  for source, contract in pairs(M.restart_actionable_epoch_sources()) do
    local state = "actionable_epoch_sources." .. tostring(source)
    if contract.durable ~= true then
      append_error(errors, state .. ": source must be durable", "actionable_epoch_registry", state)
    end
    if contract.opens_generation ~= true then
      append_error(errors, state .. ": source must open a generation", "actionable_epoch_registry", state)
    end
    if type(contract.allowed_when) ~= "string" or contract.allowed_when == "" then
      append_error(errors, state .. ": source must declare allowed_when", "actionable_epoch_registry", state)
    end
    if type(contract.excludes_deferred_time) ~= "boolean" then
      append_error(errors, state .. ": source must declare excludes_deferred_time", "actionable_epoch_registry", state)
    end
  end
end

local function validate_watchdog(row, state, contract, errors)
  local watchdog = row.watchdog
  if type(watchdog) ~= "table" then
    append_error(errors, state .. ": non-terminal row must declare watchdog", "watchdog", state)
    return
  end
  if watchdog.mode ~= "row-budget-bounds-receiver" and watchdog.mode ~= "live-defer" then
    append_error(errors, state .. ": watchdog.mode must declare exactly one supported mode", "watchdog", state)
  elseif type(contract) == "table" and watchdog.mode ~= contract.mode then
    append_error(errors, state .. ": watchdog.mode must match liveness_contract.mode", "watchdog", state)
  end
  local budget_ms = tonumber(watchdog.budget_ms)
  local budget_minutes = tonumber(row.budget and row.budget.minutes)
  local row_budget_ms = budget_minutes and budget_minutes * 60000 or nil
  if budget_ms == nil or budget_ms <= 0 then
    append_error(errors, state .. ": watchdog.budget_ms must be positive", "watchdog", state)
  elseif row_budget_ms ~= nil and budget_ms ~= row_budget_ms then
    append_error(errors, state .. ": watchdog.budget_ms must match budget.minutes", "watchdog", state)
  end
end

function S.validate_defer(M, row, state, contract, errors)
  if not row_can_live_defer(row) then
    return
  end
  local defer = row.defer
  if type(defer) ~= "table" then
    append_error(errors, state .. ": live-defer row must declare defer", "actionable_epoch", state)
    return
  end
  local signal = contract and contract.signal or nil
  if type(defer.live_marker) ~= "string" or defer.live_marker == "" then
    append_error(errors, state .. ": live-defer row must declare defer.live_marker", "actionable_epoch", state)
  elseif type(signal) == "table" and defer.live_marker ~= signal.family then
    append_error(errors, state .. ": defer.live_marker must match live-defer signal family", "actionable_epoch", state)
  elseif M.restart_durable_marker_fields()[defer.live_marker] == nil then
    append_error(errors, state .. ": defer.live_marker marker family does not exist: " .. tostring(defer.live_marker), "actionable_epoch", state)
  end
  if tonumber(defer.freshness_ms) == nil or tonumber(defer.freshness_ms) <= 0 then
    append_error(errors, state .. ": live-defer row must declare positive defer.freshness_ms", "actionable_epoch", state)
  end
  if type(defer.clear_fact) ~= "string" or defer.clear_fact == "" then
    append_error(errors, state .. ": live-defer row must declare durable defer.clear_fact", "actionable_epoch", state)
  end
  if type(defer.observed_fact) ~= "string" or defer.observed_fact == "" then
    append_error(errors, state .. ": live-defer row must declare durable defer.observed_fact", "actionable_epoch", state)
  end
  if defer.clear_opens_generation ~= true then
    append_error(errors, state .. ": live-defer row must declare defer.clear_opens_generation", "actionable_epoch", state)
  end
end

function S.validate_row(M, row, state, contract, errors)
  if type(row.liveness_class_id) ~= "string" or row.liveness_class_id == "" then
    append_error(errors, state .. ": non-terminal row must declare liveness_class_id", "actionable_epoch", state)
  end
  validate_watchdog(row, state, contract, errors)
  local actionable_epoch = row.actionable_epoch
  if type(actionable_epoch) ~= "table" then
    append_error(errors, state .. ": non-terminal row must declare actionable_epoch", "actionable_epoch", state)
    return
  end
  if actionable_epoch.generation_source ~= "same_as_actionable_epoch" then
    append_error(errors, state .. ": actionable_epoch.generation_source must be same_as_actionable_epoch", "actionable_epoch", state)
  end
  local source = actionable_epoch.source
  local source_contract = M.restart_actionable_epoch_sources()[tostring(source or "")]
  if type(source) ~= "string" or source == "" then
    append_error(errors, state .. ": actionable_epoch.source is missing", "actionable_epoch", state)
    return
  end
  if source_contract == nil then
    append_error(errors, state .. ": actionable_epoch.source is not registered: " .. tostring(source), "actionable_epoch", state)
    return
  end
  if source_contract.durable ~= true or source_contract.opens_generation ~= true then
    append_error(errors, state .. ": actionable_epoch.source must be durable and open a generation", "actionable_epoch", state)
  end
  if row_can_live_defer(row) and source_contract.excludes_deferred_time ~= true then
    append_error(errors, state .. ": live-defer row actionable_epoch.source must exclude deferred time", "actionable_epoch", state)
  end
  if source == "state_entry:v1" and row_can_live_defer(row) then
    append_error(errors, state .. ": state_entry:v1 is only allowed when no defer is possible", "actionable_epoch", state)
  end
  if source_contract.requires_clear_fact == true then
    local clear_fact = row.defer and row.defer.clear_fact or nil
    if type(clear_fact) ~= "string" or clear_fact == "" then
      append_error(errors, state .. ": actionable_epoch.source requires durable defer.clear_fact", "actionable_epoch", state)
    end
  end
  if source_contract.requires_live_marker == true then
    local live_marker = row.defer and row.defer.live_marker or nil
    if type(live_marker) ~= "string" or live_marker == "" then
      append_error(errors, state .. ": actionable_epoch.source requires defer.live_marker", "actionable_epoch", state)
    end
  end
  if source_contract.requires_observed_fact == true then
    local observed_fact = row.defer and row.defer.observed_fact or nil
    if type(observed_fact) ~= "string" or observed_fact == "" then
      append_error(errors, state .. ": actionable_epoch.source requires durable defer.observed_fact", "actionable_epoch", state)
    end
  end
end

function S.inventory_checked_records(records, enforce_exact_inventory)
  local by_listed_state = {}
  local actionable_unlisted = {}
  local filtered = {}
  for _, record in ipairs(records or {}) do
    if type(record) ~= "table" then
      table.insert(filtered, record)
    elseif record.kind == "actionable_epoch"
      and known_liveness_contract_violations[record.state] == true
      and is_known_live_defer_state_entry_violation(record) then
      by_listed_state[record.state] = true
    elseif record.kind == "actionable_epoch" then
      actionable_unlisted[record.state or "?"] = true
      table.insert(filtered, record)
    else
      table.insert(filtered, record)
    end
  end
  if enforce_exact_inventory == true then
    for state, _ in pairs(known_liveness_contract_violations) do
      if by_listed_state[state] ~= true then
        append_error(filtered, state .. ": known_liveness_contract_violations entry is not a real actionable_epoch violation", "actionable_epoch_inventory", state)
      end
    end
  end
  for state, _ in pairs(actionable_unlisted) do
    append_error(filtered, state .. ": unlisted actionable_epoch violation", "actionable_epoch_inventory", state)
  end
  return filtered
end

return S
