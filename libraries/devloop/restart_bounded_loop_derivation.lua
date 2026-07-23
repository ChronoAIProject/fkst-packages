local M = {}

local LOOP_CLASS_ORDER = {
  "self-loop",
  "release",
  "timeout",
  "stale-lineage",
}

local CAS_BASES_WITH_STALE = {
  plain = true,
  versioned = true,
  cyclic = true,
}

local EXPECTED_DECISION_FIELDS = {
  "loop_class",
  "edge_id",
  "row_id",
  "edge_kind",
  "source_state",
  "target",
  "signal_field",
  "budget_minutes",
  "cas_policy_id",
  "cas_base",
  "cas_evidence_type",
}

local function dense_table_count(value, context)
  if type(value) ~= "table" then
    error("devloop.restart_obligations: " .. context .. " must be an array")
  end
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(item) ~= "table" then
      error("devloop.restart_obligations: " .. context .. " must be an array of tables")
    end
    count = count + 1
  end
  if count ~= #value then
    error("devloop.restart_obligations: " .. context .. " must be a dense array")
  end
end

local function is_dense_string_array(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(item) ~= "string" then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local function matching_successor(row, edge)
  local signature = type(row) == "table" and row.responsibility_signature or nil
  for _, successor in ipairs(type(signature) == "table" and signature.successors or {}) do
    if successor.state == edge.target and successor.output_variant == edge.semantic_variant then
      return successor
    end
  end
  return nil
end

local function expected_decision(loop_class, signal_field, edge, budget_minutes, policy)
  return {
    loop_class = loop_class,
    edge_id = edge.id,
    row_id = edge.row_id,
    edge_kind = edge.kind,
    source_state = edge.source.state,
    target = edge.target,
    signal_field = signal_field,
    budget_minutes = budget_minutes,
    cas_policy_id = edge.cas_policy_id,
    cas_base = type(policy) == "table" and policy.base or nil,
    cas_evidence_type = type(policy) == "table" and policy.evidence_type or nil,
  }
end

local function same_expected_decision(actual, expected)
  if type(actual) ~= "table" then
    return false
  end
  for _, field in ipairs(EXPECTED_DECISION_FIELDS) do
    if actual[field] ~= expected[field] then
      return false
    end
  end
  return true
end

function M.new(primitives)
  local K = {}
  local define = primitives.define
  local require_nonempty_string = primitives.require_nonempty_string
  local policy_definition = primitives.policy_definition

  function K.bounded_loop_representatives(rows, owner_edges)
    dense_table_count(rows, "rows")
    dense_table_count(owner_edges, "owner_edges")

    local rows_by_id = {}
    for _, row in ipairs(rows) do
      require_nonempty_string(row.from_state, "rows row.from_state")
      if rows_by_id[row.from_state] ~= nil then
        error("devloop.restart_obligations: duplicate row id " .. row.from_state)
      end
      rows_by_id[row.from_state] = row
    end

    local representatives = {}
    local owner = nil
    local seen_edge_ids = {}
    for _, edge in ipairs(owner_edges) do
      require_nonempty_string(edge.id, "owner_edges edge.id")
      require_nonempty_string(edge.owner, "owner_edges edge.owner")
      require_nonempty_string(edge.row_id, "owner_edges edge.row_id")
      require_nonempty_string(edge.kind, "owner_edges edge.kind")
      require_nonempty_string(edge.target, "owner_edges edge.target")
      if type(edge.source) ~= "table" then
        error("devloop.restart_obligations: owner_edges edge.source must be a table")
      end
      if owner ~= nil and edge.owner ~= owner then
        error("devloop.restart_obligations: owner_edges must belong to one owner")
      end
      owner = edge.owner
      if seen_edge_ids[edge.id] then
        error("devloop.restart_obligations: duplicate edge id " .. edge.id)
      end
      seen_edge_ids[edge.id] = true

      local row = rows_by_id[edge.row_id]
      if row == nil then
        error("devloop.restart_obligations: missing canonical row " .. edge.row_id)
      end
      local budget = row.budget
      local budget_minutes = type(budget) == "table" and budget.minutes or nil
      local has_row_budget = type(budget_minutes) == "number" and budget_minutes > 0
      local successor = matching_successor(row, edge)
      local defer = row.defer
      local policy = nil
      if edge.cas_policy_id ~= nil then
        require_nonempty_string(edge.cas_policy_id, "owner_edges edge.cas_policy_id")
        policy = policy_definition(edge.cas_policy_id)
        if type(policy) ~= "table" then
          error("devloop.restart_obligations: unknown edge.cas_policy_id " .. edge.cas_policy_id)
        end
      end

      local direct_self_loop = edge.source.state ~= nil and edge.source.state == edge.target
      local review_phase_reentry = edge.kind == "entry"
        and edge.row_id == edge.target
        and type(policy) == "table"
        and policy.evidence_type == "review_loop_safe_cas_evidence_v1"
      local signals = {
        ["self-loop"] = has_row_budget and (direct_self_loop or review_phase_reentry),
        release = has_row_budget
          and type(defer) == "table"
          and defer.clear_opens_generation == true
          and type(successor) == "table"
          and successor.bump == true,
        timeout = has_row_budget
          and edge.kind == "timeout"
          and type(edge.timeout_evidence_policy_id) == "string"
          and edge.timeout_evidence_policy_id ~= "",
        ["stale-lineage"] = type(policy) == "table"
          and CAS_BASES_WITH_STALE[policy.base] == true,
      }
      local signal_fields = {
        ["self-loop"] = direct_self_loop
          and "edge.source.state=edge.target+row.budget.minutes"
          or "edge.kind+edge.row_id=edge.target+cas_policy.evidence_type+row.budget.minutes",
        release = "row.defer.clear_opens_generation+responsibility_signature.successors[].bump+row.budget.minutes",
        timeout = "edge.kind+edge.timeout_evidence_policy_id+row.budget.minutes",
        ["stale-lineage"] = "restart_cas_catalog.definition(edge.cas_policy_id).base",
      }

      for _, loop_class in ipairs(LOOP_CLASS_ORDER) do
        if signals[loop_class] and representatives[loop_class] == nil then
          local signal_field = signal_fields[loop_class]
          representatives[loop_class] = {
            owner = edge.owner,
            edge_id = edge.id,
            loop_class = loop_class,
            loop_signal_field = signal_field,
            expected_decision = expected_decision(
              loop_class,
              signal_field,
              edge,
              budget_minutes,
              policy
            ),
          }
        end
      end
    end

    local ordered = {}
    for _, loop_class in ipairs(LOOP_CLASS_ORDER) do
      if representatives[loop_class] ~= nil then
        table.insert(ordered, representatives[loop_class])
      end
    end
    return ordered
  end

  function K.derive_bounded_loop(rows, owner_edges, witness_index)
    if type(witness_index) ~= "table" then
      error("devloop.restart_obligations: witness_index must be a table")
    end

    local obligations = {}
    local unmapped = {}
    for _, representative in ipairs(K.bounded_loop_representatives(rows, owner_edges)) do
      local key = representative.loop_class .. "\n" .. representative.edge_id
      local witness = witness_index[key]
      local unmapped_reason = nil
      if witness == nil then
        unmapped_reason = "missing-frozen-witness"
      elseif type(witness) ~= "table"
          or witness.owner ~= representative.owner
          or witness.edge_id ~= representative.edge_id
          or witness.loop_class ~= representative.loop_class
          or witness.signal_field ~= representative.loop_signal_field
          or not same_expected_decision(
            witness.expected_decision,
            representative.expected_decision
          )
          or type(witness.input_fixture_id) ~= "string"
          or witness.input_fixture_id == ""
          or type(witness.witness_id) ~= "string"
          or witness.witness_id == ""
          or not is_dense_string_array(witness.expected_effect_ids)
          or type(witness.expected_payload_obligations) ~= "table" then
        unmapped_reason = "frozen-witness-bounded-loop-mismatch"
      end

      if unmapped_reason ~= nil then
        table.insert(unmapped, {
          owner = representative.owner,
          edge_id = representative.edge_id,
          loop_class = representative.loop_class,
          signal_field = representative.loop_signal_field,
          reason = unmapped_reason,
        })
      else
        table.insert(obligations, {
          obligation_id = representative.edge_id
            .. "/bounded-loop/" .. representative.loop_class,
          owner = representative.owner,
          edge_id = representative.edge_id,
          loop_class = representative.loop_class,
          signal_field = representative.loop_signal_field,
          case_kind = "bounded-loop",
          input_fixture_id = witness.input_fixture_id,
          expected_decision = witness.expected_decision,
          expected_effect_ids = witness.expected_effect_ids,
          expected_payload_obligations = witness.expected_payload_obligations,
          witness_id = witness.witness_id,
        })
      end
    end

    define(obligations)
    return {
      obligations = obligations,
      unmapped = unmapped,
    }
  end

  return K
end

return M
