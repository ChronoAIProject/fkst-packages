local restart_edges = require("devloop.restart_edges")

local M = {}

local SCHEMA = "restart-transition-anomaly.v1"
local CAUSE_STATUSES = {
  complete = true,
  incomplete = true,
  invalid = true,
  indeterminate = true,
}

local function is_nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function copy_value(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[copy_value(key)] = copy_value(item)
  end
  return result
end

local function dense_array_error(value, context)
  if type(value) ~= "table" then
    return context .. "-not-array"
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return context .. "-not-dense"
    end
    count = count + 1
  end
  if count ~= #value then
    return context .. "-not-dense"
  end
  return nil
end

local function append_all(target, values)
  for _, value in ipairs(values) do
    table.insert(target, value)
  end
end

local function canonical_edges(owner, rows)
  local edges = {}
  append_all(edges, restart_edges.extract_entry_edges(owner, {}, rows))
  append_all(edges, restart_edges.extract_autonomous_edges(owner, rows))
  append_all(edges, restart_edges.extract_guard_boundary_edges(owner, rows))
  append_all(edges, restart_edges.extract_timeout_edges(owner, rows))
  return edges
end

local function evidence_refs(marker_from, marker_target, observed)
  local refs = {}
  local seen = {}
  local function insert(value)
    if is_nonempty_string(value) and not seen[value] then
      seen[value] = true
      table.insert(refs, value)
    end
  end
  insert(type(marker_from) == "table" and marker_from.evidence_ref or nil)
  insert(type(marker_target) == "table" and marker_target.evidence_ref or nil)
  if type(observed) == "table" and type(observed.evidence_refs) == "table" then
    for _, value in ipairs(observed.evidence_refs) do
      insert(value)
    end
  end
  return refs
end

local function anomaly(context, fields)
  return {
    schema = SCHEMA,
    owner = context.owner,
    entity = copy_value(context.entity),
    observed_from = fields.observed_from,
    observed_target = fields.observed_target,
    edge_kind = fields.edge_kind,
    edge_id = fields.edge_id,
    cas_policy_id = fields.cas_policy_id,
    observed_generation = fields.observed_generation,
    observed_epoch = fields.observed_epoch,
    decision_status = fields.decision_status,
    reason_code = fields.reason_code,
    cause_status = fields.cause_status,
    ordering_status = fields.ordering_status,
    evidence_refs = copy_value(fields.evidence_refs or {}),
    disposition = fields.disposition,
  }
end

local function malformed(context, reason_code, marker_from, marker_target, observed, ordering_status)
  return anomaly(context, {
    observed_from = type(marker_from) == "table" and marker_from.state or nil,
    observed_target = type(marker_target) == "table" and marker_target.state or nil,
    edge_kind = type(observed) == "table" and observed.edge_kind or nil,
    edge_id = type(observed) == "table" and observed.edge_id or nil,
    cas_policy_id = type(observed) == "table" and observed.cas_policy_id or nil,
    observed_generation = type(marker_target) == "table" and marker_target.generation or nil,
    observed_epoch = type(marker_target) == "table" and marker_target.epoch or nil,
    decision_status = "invalid",
    reason_code = reason_code,
    cause_status = "invalid",
    ordering_status = ordering_status or "indeterminate",
    evidence_refs = evidence_refs(marker_from, marker_target, observed),
    disposition = "malformed-evidence",
  })
end

local function marker_order(marker)
  if marker.order ~= nil then
    return marker.order
  end
  if marker.sequence ~= nil then
    return marker.sequence
  end
  return marker.ordinal
end

local function ordering_problem(history)
  if #history < 2 then
    return nil
  end
  local previous = marker_order(history[1])
  if previous == nil then
    return "ordering-evidence-insufficient"
  end
  if type(previous) ~= "number" and type(previous) ~= "string" then
    return "marker-order-invalid"
  end
  for index = 2, #history do
    local current = marker_order(history[index])
    if current == nil then
      return "ordering-evidence-insufficient"
    end
    if type(current) ~= type(previous) then
      return "marker-order-invalid"
    end
    if current == previous then
      return "duplicate-marker-order"
    end
    if current < previous then
      return "out-of-order-marker-history"
    end
    previous = current
  end
  return nil
end

local function valid_optional_string(value)
  return value == nil or is_nonempty_string(value)
end

local function transition_error(observed)
  if type(observed) ~= "table" then
    return "transition-evidence-invalid"
  end
  if not valid_optional_string(observed.observed_from)
      or not valid_optional_string(observed.observed_target)
      or not valid_optional_string(observed.edge_kind)
      or not valid_optional_string(observed.edge_id)
      or not valid_optional_string(observed.cas_policy_id) then
    return "transition-field-invalid"
  end
  if observed.cause_status ~= nil and CAUSE_STATUSES[observed.cause_status] ~= true then
    return "cause-status-invalid"
  end
  local refs_error = dense_array_error(observed.evidence_refs or {}, "evidence-refs")
  if refs_error ~= nil then
    return refs_error
  end
  for _, ref in ipairs(observed.evidence_refs or {}) do
    if not is_nonempty_string(ref) then
      return "evidence-ref-invalid"
    end
  end
  return nil
end

local function matches_edge(edge, observed_from, observed_target, observed)
  return edge.id == observed.edge_id
    and edge.source.state == observed_from
    and edge.target == observed_target
    and edge.kind == observed.edge_kind
    and edge.cas_policy_id == observed.cas_policy_id
end

function M.schema()
  return {
    schema = SCHEMA,
    dispositions = {
      ["illegal-transition"] = true,
      ["ordering-indeterminate"] = true,
      ["cause-indeterminate"] = true,
      ["malformed-evidence"] = true,
    },
    cause_statuses = copy_value(CAUSE_STATUSES),
    ordering_statuses = { complete = true, indeterminate = true },
  }
end

function M.analyze_observed_transition_history(canonical_rows, marker_history, observed_evidence)
  local raw_owner = type(observed_evidence) == "table" and observed_evidence.owner or nil
  local raw_entity = type(observed_evidence) == "table" and observed_evidence.entity or nil
  local context = {
    owner = is_nonempty_string(raw_owner) and raw_owner or "unknown",
    entity = type(raw_entity) == "table" and raw_entity or {},
  }
  if not is_nonempty_string(raw_owner) then
    return { malformed(context, "owner-invalid") }
  end
  if type(raw_entity) ~= "table" then
    return { malformed(context, "entity-invalid") }
  end
  local rows_error = dense_array_error(canonical_rows, "canonical-rows")
  if rows_error ~= nil then
    return { malformed(context, rows_error) }
  end
  local history_error = dense_array_error(marker_history, "marker-history")
  if history_error ~= nil then
    return { malformed(context, history_error) }
  end
  local transitions = observed_evidence.transitions
  local transitions_error = dense_array_error(transitions, "observed-transitions")
  if transitions_error ~= nil then
    return { malformed(context, transitions_error) }
  end

  for _, marker in ipairs(marker_history) do
    if type(marker) ~= "table" or not is_nonempty_string(marker.state) then
      return { malformed(context, "marker-state-invalid", marker) }
    end
  end

  local order_reason = ordering_problem(marker_history)
  if order_reason == "marker-order-invalid" then
    return { malformed(context, order_reason, marker_history[1], marker_history[2]) }
  end
  if order_reason ~= nil then
    local marker_from = marker_history[1]
    local marker_target = marker_history[2]
    local observed = transitions[1]
    return { anomaly(context, {
      observed_from = marker_from and marker_from.state or nil,
      observed_target = marker_target and marker_target.state or nil,
      edge_kind = observed and observed.edge_kind or nil,
      edge_id = observed and observed.edge_id or nil,
      cas_policy_id = observed and observed.cas_policy_id or nil,
      observed_generation = marker_target and marker_target.generation or nil,
      observed_epoch = marker_target and marker_target.epoch or nil,
      decision_status = "indeterminate",
      reason_code = order_reason,
      cause_status = observed and observed.cause_status or "indeterminate",
      ordering_status = "indeterminate",
      evidence_refs = evidence_refs(marker_from, marker_target, observed),
      disposition = "ordering-indeterminate",
    }) }
  end

  local ok, edges = pcall(canonical_edges, raw_owner, canonical_rows)
  if not ok then
    return { malformed(context, "canonical-rows-invalid") }
  end
  local expected_transitions = math.max(#marker_history - 1, 0)
  local results = {}
  for index = 1, expected_transitions do
    local marker_from = marker_history[index]
    local marker_target = marker_history[index + 1]
    local observed = transitions[index]
    if observed == nil then
      table.insert(results, anomaly(context, {
        observed_from = marker_from.state,
        observed_target = marker_target.state,
        observed_generation = marker_target.generation,
        observed_epoch = marker_target.epoch,
        decision_status = "indeterminate",
        reason_code = "cause-evidence-insufficient",
        cause_status = "indeterminate",
        ordering_status = "complete",
        evidence_refs = evidence_refs(marker_from, marker_target),
        disposition = "cause-indeterminate",
      }))
    else
      local observed_error = transition_error(observed)
      if observed_error ~= nil then
        table.insert(results, malformed(
          context,
          observed_error,
          marker_from,
          marker_target,
          observed,
          "complete"
        ))
      elseif observed.observed_from ~= nil and observed.observed_from ~= marker_from.state
          or observed.observed_target ~= nil and observed.observed_target ~= marker_target.state then
        table.insert(results, malformed(
          context,
          "transition-marker-conflict",
          marker_from,
          marker_target,
          observed,
          "complete"
        ))
      elseif observed.cause_status ~= "complete"
          or observed.edge_kind == nil or observed.edge_id == nil then
        table.insert(results, anomaly(context, {
          observed_from = marker_from.state,
          observed_target = marker_target.state,
          edge_kind = observed.edge_kind,
          edge_id = observed.edge_id,
          cas_policy_id = observed.cas_policy_id,
          observed_generation = marker_target.generation,
          observed_epoch = marker_target.epoch,
          decision_status = "indeterminate",
          reason_code = "cause-evidence-insufficient",
          cause_status = observed.cause_status or "indeterminate",
          ordering_status = "complete",
          evidence_refs = evidence_refs(marker_from, marker_target, observed),
          disposition = "cause-indeterminate",
        }))
      else
        local supported = false
        for _, edge in ipairs(edges) do
          if matches_edge(edge, marker_from.state, marker_target.state, observed) then
            supported = true
            break
          end
        end
        if not supported then
          table.insert(results, anomaly(context, {
            observed_from = marker_from.state,
            observed_target = marker_target.state,
            edge_kind = observed.edge_kind,
            edge_id = observed.edge_id,
            cas_policy_id = observed.cas_policy_id,
            observed_generation = marker_target.generation,
            observed_epoch = marker_target.epoch,
            decision_status = "illegal",
            reason_code = "unsupported-explicit-edge",
            cause_status = "complete",
            ordering_status = "complete",
            evidence_refs = evidence_refs(marker_from, marker_target, observed),
            disposition = "illegal-transition",
          }))
        end
      end
    end
  end
  if #transitions > expected_transitions then
    table.insert(results, malformed(context, "orphan-transition-evidence"))
  end
  return results
end

return M
