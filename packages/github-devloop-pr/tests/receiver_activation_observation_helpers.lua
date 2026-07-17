local github_fake = require("forge.github_fake")
local git_fake = require("forge.git_fake")
local git_adapter = require("forge.git")
local github_factory = require("devloop.github_factory")
local command_support = require("devloop.commands.support")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local sink_inventory = require("core.restart.sink_inventory")

local M = {}
local active_ports = nil
local production_github_handle = github_factory.production_handle
local production_git_handle = command_support.git
local production_git_adapter_handle = git_adapter.production_handle
local github_port_proxy = setmetatable({}, {
  __index = function(_, key)
    return function(...)
      local handle = active_ports and active_ports.github or production_github_handle()
      local operation = handle[key]
      if type(operation) ~= "function" then
        error("receiver activation observation: missing GitHub port operation " .. tostring(key), 0)
      end
      return operation(...)
    end
  end,
})
github_factory.production_handle = function()
  return github_port_proxy
end
command_support.git = function()
  return active_ports and active_ports.git or production_git_handle()
end
git_adapter.production_handle = function(context)
  return active_ports and active_ports.git or production_git_adapter_handle(context)
end

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

function M.record_write(model, kind, fields)
  local entry = fields or {}
  entry.kind = kind
  table.insert(model.writes, entry)
  return entry
end

function M.fake_ports()
  local github_model = github_fake.model()
  local github = github_fake.new(github_model)
  local git_model = git_fake.model()
  local git = git_fake.new(git_model)
  function github._exec(argv, timeout, context)
    error("receiver activation observation: unexpected GitHub adapter call "
      .. M.canonical_json({ argv = argv, timeout = timeout, context = context }), 0)
  end
  function git._exec(argv, timeout, context)
    error("receiver activation observation: unexpected Git adapter call "
      .. M.canonical_json({ argv = argv, timeout = timeout, context = context }), 0)
  end
  return {
    github = github,
    git = git,
    github_model = github_model,
    git_model = git_model,
  }
end

function M.make_department(module, ports, core)
  local department = {
    spec = module.spec,
    ports = { github = ports.github, git = ports.git },
    model = ports.github_model,
  }
  department.pipeline = function(event)
    local previous_ports = active_ports
    local previous_git = core.git
    active_ports = ports
    core.git = ports.git
    local ok, result = pcall(module.pipeline, event)
    core.git = previous_git
    active_ports = previous_ports
    if not ok then error(result, 0) end
    return result
  end
  return department
end

local function inventory_effect(dept, effect_id)
  local selected = nil
  for _, effect in ipairs(sink_inventory) do
    if effect.id == effect_id and effect.callsite
      and (effect.callsite.department == dept or effect.callsite.department == "all") then
      if selected ~= nil then error("duplicate receiver activation sink " .. effect_id, 0) end
      selected = effect
    end
  end
  if selected == nil then error("missing receiver activation sink " .. tostring(dept) .. ":" .. effect_id, 0) end
  return selected
end

function M.effects(dept, fixture, raises, captured)
  local emitted = M.json_array()
  local writes = M.json_array()
  local raise_index = 0
  for ordinal, actual in ipairs(captured.effect_sequence) do
    local effect_id = fixture.effects and fixture.effects[ordinal]
    if effect_id == nil then error(fixture.disposition .. ": unclassified emitted effect", 0) end
    local inventory = inventory_effect(dept, effect_id)
    table.insert(emitted, {
      effect_id = inventory.id,
      sink_kind = inventory.effect_kind,
      authority_class = inventory.authority_class,
      ordinal = ordinal,
    })
    if actual.kind == "raise" then
      raise_index = raise_index + 1
      local raised = raises[raise_index]
      if raised == nil or raised.queue ~= actual.queue then
        error(fixture.disposition .. ": raise ordering drift", 0)
      end
      table.insert(writes, {
        effect_id = inventory.id,
        queue = raised.queue,
        payload = M.copy_value(raised.payload),
      })
    else
      table.insert(writes, {
        effect_id = inventory.id,
        adapter_call = M.copy_value(actual.call),
      })
    end
  end
  if raise_index ~= #(raises or {}) then error(fixture.disposition .. ": unclassified raise", 0) end
  if #captured.effect_sequence ~= #(fixture.effects or {}) then
    error(fixture.disposition .. ": emitted effect count drift", 0)
  end
  return emitted, writes
end

function M.capture_logging(dept, devloop_logging, restorations)
  local captured = {
    decisions = M.json_array(),
    applies = M.json_array(),
    gates = M.json_array(),
    effect_sequence = M.json_array(),
  }
  local original_decision = devloop_logging.log_cas_decision
  local original_apply = devloop_logging.log_apply
  local original_raise = devloop_logging.log_raise
  local original_line = devloop_logging.log_line
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
    if actual_dept == dept then table.insert(captured.effect_sequence, { kind = "raise", queue = queue }) end
    return original_raise(actual_dept, proposal_id, queue, payload)
  end, restorations)
  M.replace(devloop_logging, "log_line", function(level, actual_dept, proposal_id, tag, fields)
    if actual_dept == dept and tag == "GATE" then
      local gate = { proposal_id = proposal_id }
      for _, field in ipairs(fields or {}) do
        local key, value = tostring(field):match("^([^=]+)=(.*)$")
        if key ~= nil then gate[key] = value end
      end
      table.insert(captured.gates, gate)
    end
    return original_line(level, actual_dept, proposal_id, tag, fields)
  end, restorations)
  return captured
end

local function effect_ids(effects)
  local ids = M.json_array()
  for _, effect in ipairs(effects or {}) do table.insert(ids, effect.effect_id) end
  return ids
end

function M.record(opts)
  local emitted, writes = M.effects(opts.dept, opts.fixture, opts.result.raises, opts.captured)
  local fixture = opts.fixture
  return {
    schema = "restart-old-behavior-observation.v2",
    observation_id = opts.prefix .. fixture.disposition,
    owner = "github-devloop-pr",
    site = M.copy_value(opts.site),
    boundary = opts.boundary or "receiver_activation",
    typed_intent = {
      kind = opts.boundary or "receiver_activation",
      source_state = opts.source_state,
      source_boundary = opts.event.queue,
      target = fixture.target,
      cause_schema_id = tostring(opts.event.payload.schema or "missing-schema"),
      generation_epoch = {
        current_version = M.nullable(fixture.current_version),
        request_version = M.nullable(opts.event.payload.dedup_key),
        effect_version = M.nullable(fixture.effect_version),
      },
      lineage = {
        proposal_id = M.nullable(opts.event.payload.proposal_id or fixture.proposal_id),
        issue_number = M.nullable(fixture.issue_number),
        pr_number = M.nullable(opts.event.payload.pr_number or opts.event.payload.number),
        source_ref = M.nullable(M.copy_value(opts.event.payload.source_ref)),
      },
    },
    old_inputs = {
      current_fact = M.copy_value(fixture.current_fact or {}),
      caller_from_states = M.json_array({ opts.source_state }),
      incoming_version = M.nullable(opts.event.payload.version or opts.event.payload.dedup_key),
      target_version = M.nullable(fixture.effect_version),
      handoff_reference = M.nullable(M.copy_value(opts.event.payload.reviewing_hand_off)),
    },
    old_outcome = {
      status = fixture.status,
      reason_code = fixture.reason,
      cas_outcome = fixture.cas,
      emitted_effects = emitted,
      observable_writes = writes,
      handoff_direct_lookup_count = fixture.handoff_lookup_count or 0,
      timeout_evidence_source = M.JSON_NULL,
    },
    evidence_refs = M.json_array({
      { kind = opts.boundary == "entry_acceptor" and "runtime-entry-acceptor" or "runtime-receiver-activation",
        ref = (opts.evidence_path or opts.site.path) .. ":" .. tostring(fixture.source_line) },
      { kind = "runtime-event-source", ref = opts.event.queue },
    }),
  }
end

local function tuple_from_fixture(fixture)
  return table.concat({ fixture.disposition, fixture.status, fixture.reason, fixture.cas, fixture.target,
    table.concat(fixture.effects or {}, ",") }, "|")
end

local function tuple_from_record(record, prefix)
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

local function assert_same_set(actual, expected, actual_label, expected_label)
  for value in pairs(actual) do
    if not expected[value] then error(actual_label .. " tuple absent from " .. expected_label .. ": " .. value, 0) end
  end
  for value in pairs(expected) do
    if not actual[value] then error(expected_label .. " tuple absent from " .. actual_label .. ": " .. value, 0) end
  end
end

function M.assert_site(t, opts)
  local boundary_label = opts.boundary or "receiver_activation"
  local first = M.json_array()
  local second = M.json_array()
  for _, fixture in ipairs(opts.fixtures) do
    local ok, record = pcall(opts.capture, fixture)
    if not ok then error(tostring(fixture.disposition) .. ": " .. tostring(record), 0) end
    table.insert(first, record)
  end
  for _, fixture in ipairs(opts.fixtures) do
    local ok, record = pcall(opts.capture, fixture)
    if not ok then error(tostring(fixture.disposition) .. " repeat: " .. tostring(record), 0) end
    table.insert(second, record)
  end
  table.sort(first, function(a, b) return a.observation_id < b.observation_id end)
  table.sort(second, function(a, b) return a.observation_id < b.observation_id end)
  local repeat_difference = M.first_difference(second, first, boundary_label .. "[repeat]")
  if repeat_difference or M.canonical_json(second) ~= M.canonical_json(first) then
    error(opts.dept .. " repeated capture differs at " .. tostring(repeat_difference or "canonical-json"), 0)
  end
  local inventory = json.decode(file.read("migration/restart-lifecycle.inventory.json"))
  local committed = M.json_array()
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    local site = record.site or {}
    if site.path == opts.site.path and site.symbol == opts.site.symbol and site.ordinal == opts.site.ordinal then
      table.insert(committed, record)
    end
  end
  table.sort(committed, function(a, b) return a.observation_id < b.observation_id end)
  if #committed == 0 then
    error("missing committed " .. boundary_label .. " records; runtime_records=" .. M.canonical_json(first), 0)
  end
  local runtime_set = tuple_set(first, function(record) return tuple_from_record(record, opts.prefix) end, "runtime")
  local fixture_set = tuple_set(opts.fixtures, tuple_from_fixture, "fixture")
  local inventory_set = tuple_set(committed, function(record) return tuple_from_record(record, opts.prefix) end, "inventory")
  assert_same_set(runtime_set, fixture_set, "runtime", "fixture")
  assert_same_set(runtime_set, inventory_set, "runtime", "inventory")
  local inventory_difference = M.first_difference(first, committed, boundary_label .. "[" .. opts.dept .. "]")
  if inventory_difference or M.canonical_json(first) ~= M.canonical_json(committed) then
    error("runtime-bound OLD " .. opts.dept .. " differs at "
      .. tostring(inventory_difference or "canonical-json") .. "; runtime_records=" .. M.canonical_json(first), 0)
  end
  t.eq(#first, #opts.fixtures, opts.dept .. ": complete " .. boundary_label .. " disposition count")
end

return M
