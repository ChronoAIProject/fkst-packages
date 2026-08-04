local M = {}

local OBLIGATION_KINDS = {
  ["absence"] = true,
  ["precedence.gate-fact"] = true,
  ["precedence.structural"] = true,
  ["response-with-deadline"] = true,
}

local CAPABILITY_MATRIX = {
  ["absence"] = { status = "unmonitored", reason = "explicit-emission-ledger-provider-unavailable" },
  ["precedence.gate-fact"] = { status = "unmonitored", reason = "r7-provider-unavailable" },
  ["precedence.structural"] = { status = "unmonitored", reason = "r7-provider-unavailable" },
  ["response-with-deadline"] = {
    status = "monitored",
    provider_kind = "r8-liveness-watchdog",
  },
}

local function fail(message)
  error("devloop.restart_temporal_obligations: " .. message, 0)
end

local function is_nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy_value(item)
  end
  return out
end

local function deep_equal(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not deep_equal(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

local function validate_dense_array(value, context)
  if type(value) ~= "table" then
    fail(context .. " must be a dense array")
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      fail(context .. " must be a dense array")
    end
    count = count + 1
  end
  if count ~= #value then
    fail(context .. " must be a dense array")
  end
end

local function validate_exact_fields(value, expected, context)
  for key in pairs(value) do
    if not expected[key] then
      if key == "provider" or key == "provider_kind" or key == "provider_binding" or key == "verification" then
        fail(context .. " has a separately-authored provider binding")
      end
      fail(context .. " has unknown field " .. tostring(key))
    end
  end
  for key in pairs(expected) do
    if value[key] == nil then
      fail(context .. " is missing field " .. key)
    end
  end
end

local function row_resolver(row)
  local contract = row.liveness_contract
  if type(contract) ~= "table" then
    return nil
  end
  if type(contract.signal) == "table" and is_nonempty_string(contract.signal.resolver) then
    return contract.signal.resolver
  end
  if type(contract.real_execution) == "table" and is_nonempty_string(contract.real_execution.primitive) then
    return contract.real_execution.primitive
  end
  if is_nonempty_string(contract.mode) then
    return contract.mode
  end
  return nil
end

local function validate_response_body(row, body, context)
  if type(body) ~= "table" then
    fail(context .. ".body must be a table")
  end
  validate_exact_fields(body, {
    actionable_epoch_source = true,
    budget_minutes = true,
    resolver = true,
  }, context .. ".body")

  local epoch_source = type(row.actionable_epoch) == "table" and row.actionable_epoch.source or nil
  local budget_minutes = type(row.budget) == "table" and row.budget.minutes or nil
  local resolver = row_resolver(row)
  if body.actionable_epoch_source ~= epoch_source then
    fail(context .. ".body.actionable_epoch_source drifts from row.actionable_epoch.source")
  end
  if body.resolver ~= resolver then
    fail(context .. ".body.resolver drifts from the row R8 resolver")
  end
  if body.budget_minutes ~= budget_minutes then
    fail(context .. ".body.budget_minutes drifts from row.budget.minutes")
  end
  if not is_nonempty_string(epoch_source) or not is_nonempty_string(resolver)
      or type(budget_minutes) ~= "number" or budget_minutes <= 0 then
    fail(context .. " cannot derive complete R8 response-with-deadline evidence from its row")
  end
end

local function validate_matrix(matrix)
  if not deep_equal(matrix, CAPABILITY_MATRIX) then
    fail("provider capability matrix is not the closed canonical matrix")
  end
end

function M.provider_capability_matrix()
  return copy_value(CAPABILITY_MATRIX)
end

function M.validate_obligation(owner, row, obligation)
  local context = "row " .. tostring(row and row.from_state) .. " temporal obligation"
  if not is_nonempty_string(owner) then
    fail("owner must be a non-empty string")
  end
  if type(row) ~= "table" or not is_nonempty_string(row.from_state) then
    fail("row.from_state must be a non-empty string")
  end
  if type(obligation) ~= "table" then
    fail(context .. " must be a table")
  end
  validate_exact_fields(obligation, {
    body = true,
    kind = true,
    obligation_id = true,
  }, context)
  if not is_nonempty_string(obligation.obligation_id)
      or obligation.obligation_id:sub(1, #owner + 1) ~= owner .. "/" then
    fail(context .. ".obligation_id must be owner-local")
  end
  if not OBLIGATION_KINDS[obligation.kind] then
    fail(context .. ".kind is not in the closed obligation kind set")
  end
  if type(obligation.body) ~= "table" then
    fail(context .. ".body must be a table")
  end
  if obligation.kind == "response-with-deadline" then
    validate_response_body(row, obligation.body, context)
  end
  return true
end

function M.derive_temporal_index(owner, rows, provider_capabilities)
  if not is_nonempty_string(owner) then
    fail("owner must be a non-empty string")
  end
  validate_dense_array(rows, "rows")
  validate_matrix(provider_capabilities)

  local index = {}
  for row_index, row in ipairs(rows) do
    if type(row) ~= "table" or not is_nonempty_string(row.from_state) then
      fail("rows[" .. tostring(row_index) .. "].from_state must be a non-empty string")
    end
    local context = "row " .. row.from_state .. ".temporal_obligations"
    validate_dense_array(row.temporal_obligations, context)
    if row.terminal == true and #row.temporal_obligations ~= 0 then
      fail(context .. " must be empty for a terminal row")
    end
    if row.terminal ~= true and #row.temporal_obligations == 0 then
      fail(context .. " must author a response-with-deadline obligation")
    end

    for _, obligation in ipairs(row.temporal_obligations) do
      M.validate_obligation(owner, row, obligation)
      if index[obligation.obligation_id] ~= nil then
        fail("duplicate obligation_id " .. obligation.obligation_id)
      end
      local capability = provider_capabilities[obligation.kind]
      if type(capability) ~= "table" or capability.status ~= "monitored"
          or not is_nonempty_string(capability.provider_kind) then
        fail("obligation " .. obligation.obligation_id .. " is unmonitored/indeterminate: no capable provider")
      end
      index[obligation.obligation_id] = {
        obligation_id = obligation.obligation_id,
        owner = owner,
        row_id = row.from_state,
        kind = obligation.kind,
        body = copy_value(obligation.body),
        verification = {
          status = capability.status,
          provider_kind = capability.provider_kind,
        },
      }
    end
  end
  return index
end

function M.index_errors(owner, rows, candidate, provider_capabilities)
  local ok, expected = pcall(M.derive_temporal_index, owner, rows, provider_capabilities)
  if not ok then
    return { tostring(expected) }
  end
  if type(candidate) ~= "table" then
    return { "temporal index must be a map keyed by obligation_id" }
  end

  local errors = {}
  for obligation_id, entry in pairs(candidate) do
    if expected[obligation_id] == nil then
      table.insert(errors, "orphan index entry " .. tostring(obligation_id))
    elseif not deep_equal(entry, expected[obligation_id]) then
      table.insert(errors, "drifting index entry " .. tostring(obligation_id))
    end
  end
  for obligation_id in pairs(expected) do
    if candidate[obligation_id] == nil then
      table.insert(errors, "missing index entry " .. tostring(obligation_id))
    end
  end
  table.sort(errors)
  return errors
end

return M
