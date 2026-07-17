local observation_support = require("testkit_internal.old_behavior_observation_support")
local sink_inventory = require("core.restart.sink_inventory")

local M = {}

M.JSON_NULL = observation_support.JSON_NULL
M.canonical_json = observation_support.canonical_json
M.copy_value = observation_support.copy_value
M.first_difference = observation_support.first_difference
M.json_array = observation_support.json_array
M.nullable = observation_support.nullable

function M.replace(target, key, value, restorations)
  table.insert(restorations, { target = target, key = key, value = target[key] })
  target[key] = value
end

function M.restore_all(restorations)
  for index = #restorations, 1, -1 do
    local item = restorations[index]
    item.target[item.key] = item.value
  end
end

function M.capture_logging(dept, devloop_logging, restorations)
  local captured = {
    decisions = M.json_array(),
    applies = M.json_array(),
    effect_sequence = M.json_array(),
  }
  local original_decision = devloop_logging.log_cas_decision
  local original_apply = devloop_logging.log_apply
  local original_raise = devloop_logging.log_raise
  M.replace(devloop_logging, "log_cas_decision", function(actual_dept, proposal_id, current, from_state, to_state, outcome, reason)
    if actual_dept == dept then
      table.insert(captured.decisions, {
        proposal_id = proposal_id,
        current = M.copy_value(current),
        from_state = from_state,
        to_state = to_state,
        outcome = outcome,
        reason = reason,
      })
    end
    return original_decision(actual_dept, proposal_id, current, from_state, to_state, outcome, reason)
  end, restorations)
  M.replace(devloop_logging, "log_apply", function(actual_dept, proposal_id, to_state, version, labels, queues)
    if actual_dept == dept then
      table.insert(captured.applies, {
        proposal_id = proposal_id,
        to_state = to_state,
        version = version,
        labels = M.copy_value(labels),
        queues = M.copy_value(queues),
      })
    end
    return original_apply(actual_dept, proposal_id, to_state, version, labels, queues)
  end, restorations)
  M.replace(devloop_logging, "log_raise", function(actual_dept, proposal_id, queue, payload)
    if actual_dept == dept then
      table.insert(captured.effect_sequence, { kind = "raise", queue = queue })
    end
    return original_raise(actual_dept, proposal_id, queue, payload)
  end, restorations)
  return captured
end

local function inventory_effect(dept, effect_id)
  local selected = nil
  for _, effect in ipairs(sink_inventory) do
    if effect.id == effect_id and effect.callsite
      and (effect.callsite.department == dept or effect.callsite.department == "all") then
      if selected ~= nil then error("duplicate entry acceptor sink " .. effect_id, 0) end
      selected = effect
    end
  end
  if selected == nil then error("missing entry acceptor sink " .. tostring(dept) .. ":" .. tostring(effect_id), 0) end
  return selected
end

local function effect_ids(effects)
  local ids = M.json_array()
  for _, effect in ipairs(effects or {}) do table.insert(ids, effect.effect_id) end
  return ids
end

local function payload_summary(payload)
  local source = type(payload) == "table" and payload or {}
  local summary = {
    schema = source.schema,
    dedup_key = source.dedup_key,
    target_kind = source.target_kind,
    target_number = source.target_number or source.issue_number or source.pr_number,
    add_labels = M.copy_value(source.add_labels),
    remove_labels = M.copy_value(source.remove_labels),
    handoff_kind = type(source.handoff) == "table" and source.handoff.kind or nil,
  }
  local body = tostring(source.body or "")
  local markers = M.json_array()
  for marker in body:gmatch("<!%-%- ([^ >]+)") do table.insert(markers, marker) end
  summary.body_markers = markers
  return summary
end

function M.effects(dept, fixture, raises, captured)
  local emitted = M.json_array()
  local writes = M.json_array()
  for ordinal, actual in ipairs(captured.effect_sequence) do
    local effect_id = fixture.effects and fixture.effects[ordinal]
    if effect_id == nil then error(fixture.disposition .. ": unclassified emitted effect", 0) end
    local inventory = inventory_effect(dept, effect_id)
    local raised = raises[ordinal]
    if raised == nil or raised.queue ~= actual.queue then
      error(fixture.disposition .. ": raise ordering drift", 0)
    end
    table.insert(emitted, {
      effect_id = inventory.id,
      sink_kind = inventory.effect_kind,
      authority_class = inventory.authority_class,
      ordinal = ordinal,
    })
    table.insert(writes, {
      effect_id = inventory.id,
      queue = raised.queue,
      payload = payload_summary(raised.payload),
    })
  end
  if #captured.effect_sequence ~= #(fixture.effects or {}) or #captured.effect_sequence ~= #(raises or {}) then
    error(fixture.disposition .. ": emitted effect count drift", 0)
  end
  return emitted, writes
end

function M.record(opts)
  local fixture = opts.fixture
  local emitted, writes = M.effects(opts.dept, fixture, opts.result.raises, opts.captured)
  local payload = opts.event.payload or {}
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = opts.prefix .. fixture.disposition,
    owner = "github-devloop",
    site = M.copy_value(opts.site),
    boundary = "entry_acceptor",
    typed_intent = {
      kind = "entry_acceptor",
      source_state = fixture.source_state or opts.source_state,
      source_boundary = opts.event.queue,
      target = fixture.target,
      cause_schema_id = tostring(payload.schema or "missing-schema"),
      generation_epoch = {
        current_version = M.nullable(fixture.current_version),
        request_version = M.nullable(payload.dedup_key or payload.issue_version),
        effect_version = M.nullable(fixture.effect_version),
      },
      lineage = {
        proposal_id = M.nullable(payload.proposal_id),
        issue_number = M.nullable(fixture.issue_number),
        round = M.nullable(payload.round),
        source_ref = M.nullable(M.copy_value(payload.source_ref)),
      },
    },
    old_inputs = {
      current_fact = M.copy_value(fixture.current_fact or {}),
      caller_from_states = M.json_array({ fixture.source_state or opts.source_state }),
      incoming_version = tostring(payload.dedup_key or payload.issue_version or "missing-version"),
      target_version = M.nullable(fixture.effect_version),
      handoff_reference = M.JSON_NULL,
    },
    old_outcome = {
      status = fixture.status,
      reason_code = fixture.reason,
      cas_outcome = fixture.cas,
      emitted_effects = emitted,
      observable_writes = writes,
      handoff_direct_lookup_count = 0,
      timeout_evidence_source = M.JSON_NULL,
    },
    evidence_refs = M.json_array({
      { kind = "runtime-entry-acceptor", ref = opts.site.path .. ":" .. tostring(fixture.source_line) },
      { kind = "runtime-event-source", ref = opts.event.queue },
    }),
  }
end

local function fixture_tuple(fixture)
  return table.concat({ fixture.disposition, fixture.status, fixture.reason, fixture.cas, fixture.target,
    table.concat(fixture.effects or {}, ",") }, "|")
end

local function record_tuple(record, prefix)
  return table.concat({ record.observation_id:sub(#prefix + 1), record.old_outcome.status,
    record.old_outcome.reason_code, record.old_outcome.cas_outcome, record.typed_intent.target,
    table.concat(effect_ids(record.old_outcome.emitted_effects), ",") }, "|")
end

local function tuple_set(values, convert, label)
  local result = {}
  for _, value in ipairs(values) do
    local key = convert(value)
    if result[key] then error(label .. " duplicate tuple: " .. key, 0) end
    result[key] = true
  end
  return result
end

local function assert_bidirectional(actual, expected, actual_label, expected_label)
  for value in pairs(actual) do
    if not expected[value] then error(actual_label .. " tuple absent from " .. expected_label .. ": " .. value, 0) end
  end
  for value in pairs(expected) do
    if not actual[value] then error(expected_label .. " tuple absent from " .. actual_label .. ": " .. value, 0) end
  end
end

local function committed_records(site)
  local inventory = json.decode(file.read("migration/restart-lifecycle.inventory.json"))
  local records = M.json_array()
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    local actual = record.site or {}
    if actual.path == site.path and actual.symbol == site.symbol and actual.ordinal == site.ordinal then
      table.insert(records, record)
    end
  end
  table.sort(records, function(left, right) return left.observation_id < right.observation_id end)
  return records
end

local function capture_records(opts)
  local records = M.json_array()
  for _, fixture in ipairs(opts.fixtures) do table.insert(records, opts.capture(fixture)) end
  table.sort(records, function(left, right) return left.observation_id < right.observation_id end)
  return records
end

function M.assert_site(t, opts)
  local fixture_set = tuple_set(opts.fixtures, fixture_tuple, opts.dept .. " fixture lattice")
  local first = capture_records(opts)
  local second = capture_records(opts)
  local repeat_difference = M.first_difference(second, first, "old_behavior_observations[" .. opts.dept .. "][repeat]")
  if repeat_difference or M.canonical_json(second) ~= M.canonical_json(first) then
    error("second OLD " .. opts.dept .. " entry acceptor capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
  end
  local runtime_set = tuple_set(first, function(record) return record_tuple(record, opts.prefix) end,
    opts.dept .. " runtime records")
  assert_bidirectional(runtime_set, fixture_set, "runtime records", "production fixture lattice")
  local expected = committed_records(opts.site)
  local inventory_set = tuple_set(expected, function(record) return record_tuple(record, opts.prefix) end,
    opts.dept .. " inventory records")
  assert_bidirectional(runtime_set, inventory_set, "runtime records", "inventory records")
  local difference = M.first_difference(first, expected, "old_behavior_observations[" .. opts.dept .. "]")
  if difference or M.canonical_json(first) ~= M.canonical_json(expected) then
    error("runtime-bound OLD " .. opts.dept .. " entry acceptor observation differs at "
      .. tostring(difference or "canonical-json") .. "; runtime_records=" .. M.canonical_json(first), 0)
  end
  t.eq(#first, #opts.fixtures, opts.dept .. ": exhaustive entry acceptor count")
end

return M
