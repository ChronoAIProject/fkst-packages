local M = {}

M.JSON_NULL = json.decode("null")
M.JSON_ARRAY_TAG = getmetatable(json.decode("[]"))
M.JSON_OBJECT_TAG = getmetatable(json.decode("{}"))

local function json_string(value)
  return '"' .. tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\f", "\\f")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
    :gsub("[%z\1-\31]", function(char)
      return string.format("\\u%04x", string.byte(char))
    end)
    .. '"'
end

local function array_length(value)
  local count = 0
  local maximum = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil
    end
    count = count + 1
    if key > maximum then
      maximum = key
    end
  end
  if maximum ~= count then
    return nil
  end
  return maximum
end

function M.json_array(values)
  local array = json.decode("[]")
  for index, value in ipairs(values or {}) do
    array[index] = value
  end
  return array
end

function M.is_json_array(value)
  return type(value) == "table" and getmetatable(value) == M.JSON_ARRAY_TAG
end

local function json_container_kind(value)
  if M.is_json_array(value) then
    return "array"
  end
  local length = array_length(value)
  if length ~= nil and length > 0 then
    return "array"
  end
  return "object"
end

function M.copy_value(value)
  if type(value) ~= "table" or value == M.JSON_NULL then
    return value
  end
  local length = array_length(value)
  local copy = {}
  if M.is_json_array(value) or (length ~= nil and length > 0) then
    copy = M.json_array()
  end
  for key, field in pairs(value) do
    copy[M.copy_value(key)] = M.copy_value(field)
  end
  return copy
end

function M.nullable(value)
  if value == nil then
    return M.JSON_NULL
  end
  return value
end

function M.canonical_json(value)
  if value == M.JSON_NULL then
    return "null"
  end
  local kind = type(value)
  if kind == "string" then
    return json_string(value)
  end
  if kind == "number" or kind == "boolean" then
    return tostring(value)
  end
  if kind ~= "table" then
    error("OLD observation canonical JSON cannot encode " .. kind)
  end

  if json_container_kind(value) == "array" then
    local length = array_length(value)
    if length == nil then
      error("OLD observation canonical JSON array must be a contiguous sequence")
    end
    local items = {}
    for index = 1, length do
      items[index] = M.canonical_json(value[index])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do
    if type(key) ~= "string" then
      error("OLD observation canonical JSON object key must be a string")
    end
    table.insert(keys, key)
  end
  table.sort(keys)
  local fields = {}
  for _, key in ipairs(keys) do
    table.insert(fields, json_string(key) .. ":" .. M.canonical_json(value[key]))
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

function M.first_difference(actual, expected, path)
  if actual == expected then
    return nil
  end
  if actual == M.JSON_NULL or expected == M.JSON_NULL then
    return path .. " (actual=" .. M.canonical_json(actual) .. ", expected=" .. M.canonical_json(expected) .. ")"
  end
  if type(actual) ~= type(expected) then
    return path .. " (actual type=" .. type(actual) .. ", expected type=" .. type(expected) .. ")"
  end
  if type(actual) ~= "table" then
    return path .. " (actual=" .. M.canonical_json(actual) .. ", expected=" .. M.canonical_json(expected) .. ")"
  end
  local actual_container = json_container_kind(actual)
  local expected_container = json_container_kind(expected)
  if actual_container ~= expected_container then
    return path .. " (actual container=" .. actual_container
      .. ", expected container=" .. expected_container .. ")"
  end
  local keys = {}
  for key, _ in pairs(actual) do keys[key] = true end
  for key, _ in pairs(expected) do keys[key] = true end
  local ordered = {}
  for key, _ in pairs(keys) do table.insert(ordered, key) end
  table.sort(ordered, function(left, right) return tostring(left) < tostring(right) end)
  for _, key in ipairs(ordered) do
    if actual[key] == nil then
      return path .. "." .. tostring(key) .. " (missing from runtime capture)"
    end
    if expected[key] == nil then
      return path .. "." .. tostring(key) .. " (missing from committed record)"
    end
    local difference = M.first_difference(actual[key], expected[key], path .. "." .. tostring(key))
    if difference ~= nil then
      return difference
    end
  end
  return nil
end

function M.observe_department(opts)
  local config = opts.config or error("OLD observation config dependency is required")
  local devloop_logging = opts.devloop_logging or error("OLD observation logging dependency is required")
  local captured = {
    probes = M.json_array(),
    decisions = M.json_array(),
    applies = M.json_array(),
    raises = M.json_array(),
    lines = M.json_array(),
    handoff_direct_lookup_count = 0,
    liveness_read_count = 0,
  }
  local original_decision = devloop_logging.log_cas_decision
  local original_apply = devloop_logging.log_apply
  local original_raise = devloop_logging.log_raise
  local original_line = devloop_logging.log_line
  local original_codex_runs = fkst.codex_runs
  local original_write_mode = config.write_mode

  config.write_mode = function()
    return opts.write_mode or "real"
  end
  fkst.codex_runs = function()
    captured.liveness_read_count = captured.liveness_read_count + 1
    local running = opts.codex_runs_for_read
    if type(running) == "function" then
      running = running(captured.liveness_read_count)
    end
    return { running = running or M.json_array() }
  end
  devloop_logging.log_cas_decision = function(dept, proposal_id, current, from_state, to_state, outcome, reason)
    if dept == opts.dept and from_state == opts.from_state then
      table.insert(captured.decisions, {
        dept = dept,
        proposal_id = proposal_id,
        current = M.copy_value(current),
        from_state = from_state,
        to_state = to_state,
        outcome = outcome,
        reason = reason,
      })
    end
    return original_decision(dept, proposal_id, current, from_state, to_state, outcome, reason)
  end
  devloop_logging.log_apply = function(dept, proposal_id, to_state, version, labels, queues)
    if dept == opts.dept then
      table.insert(captured.applies, {
        proposal_id = proposal_id,
        to_state = to_state,
        version = version,
        labels = M.copy_value(labels),
        queues = M.copy_value(queues),
      })
    end
    return original_apply(dept, proposal_id, to_state, version, labels, queues)
  end
  devloop_logging.log_raise = function(dept, proposal_id, queue, payload)
    if dept == opts.dept then
      table.insert(captured.raises, {
        proposal_id = proposal_id,
        queue = queue,
        payload = M.copy_value(payload),
      })
    end
    return original_raise(dept, proposal_id, queue, payload)
  end
  devloop_logging.log_line = function(level, dept, proposal_id, event, fields)
    if dept == opts.dept then
      table.insert(captured.lines, {
        level = level,
        event = event,
        fields = M.copy_value(fields),
      })
    end
    return original_line(level, dept, proposal_id, event, fields)
  end

  local ok, result = pcall(opts.run)
  fkst.codex_runs = original_codex_runs
  config.write_mode = original_write_mode
  devloop_logging.log_line = original_line
  devloop_logging.log_raise = original_raise
  devloop_logging.log_apply = original_apply
  devloop_logging.log_cas_decision = original_decision
  if not ok then
    error(result, 0)
  end
  return result, captured
end

function M.admission_trace_write(ordinal, effect_id, payload, context)
  local write_kind = nil
  if (effect_id == "consensus.proposal"
      or effect_id == "devloop_consensus_request"
      or effect_id == "devloop_consensus_continue"
      or effect_id == "devloop_issue_decision"
      or effect_id == "devloop_review_request"
      or effect_id == "devloop_review_continue"
      or effect_id == "devloop_review_decision")
    and type(payload) == "table"
    and type(payload.schema) == "string"
    and payload.schema:find("consensus.", 1, true) == 1 then
    write_kind = "queue"
  elseif type(payload) == "table" and type(payload.body) == "string" then
    write_kind = "comment"
  elseif type(payload) == "table"
    and (type(payload.add_labels) == "table" or type(payload.remove_labels) == "table") then
    write_kind = "label"
  else
    error(
      tostring(context or "R9 admission trace")
        .. " saw an unsupported observable effect shape for "
        .. tostring(effect_id),
      0
    )
  end
  return {
    ordinal = ordinal,
    effect_id = effect_id,
    write_kind = write_kind,
    marker_write = write_kind == "comment"
      and payload.body:find("fkst:github-devloop:state:v1", 1, true) ~= nil,
  }
end

function M.admission_trace_writes(raises, context)
  local writes = M.json_array()
  for ordinal, raised in ipairs(raises or {}) do
    table.insert(
      writes,
      M.admission_trace_write(ordinal, raised.queue, raised.payload, context)
    )
  end
  return writes
end

function M.admission_trace_fixture(
  fixture,
  edge_id,
  status,
  reason_code,
  cas_outcome,
  entitlement_id,
  granted_effect_ids,
  writes
)
  return {
    fixture_id = fixture.fixture_id,
    edge_id = edge_id,
    cas_status = status,
    reason_code = reason_code,
    cas_outcome = cas_outcome,
    effect_entitlement_id = entitlement_id or M.JSON_NULL,
    granted_effect_ids = M.json_array(granted_effect_ids),
    observable_writes = writes,
  }
end

function M.admission_trace_active_projection(artifact)
  return M.copy_value(artifact)
end

function M.protected_admission_fixture(path, fixture_id)
  if type(path) ~= "string" or path == "" then
    error("protected admission corpus path is required", 0)
  end
  if type(fixture_id) ~= "string" or fixture_id == "" then
    error("protected admission fixture_id is required", 0)
  end
  local artifact = json.decode(file.read(path))
  local match = nil
  for _, fixture in ipairs(artifact.fixtures or {}) do
    if fixture.fixture_id == fixture_id then
      if match ~= nil then
        error("protected admission fixture is ambiguous: " .. fixture_id, 0)
      end
      match = fixture
    end
  end
  if match == nil then
    error("protected admission fixture is missing: " .. fixture_id, 0)
  end
  return M.copy_value(match)
end

function M.protected_admission_expectation(path, fixture_id)
  local fixture = M.protected_admission_fixture(path, fixture_id)
  return {
    status = fixture.cas_status,
    reason_code = fixture.reason_code,
    cas_outcome = fixture.cas_outcome,
  }
end

function M.admission_trace_artifact(schema, owner, family, corpus_hash, fixtures, captured_sink_effects)
  local artifact = {
    schema = schema,
    owner = owner,
    family = family,
    fixtures = fixtures,
    artifact_sha256 = corpus_hash,
  }
  if captured_sink_effects ~= nil then
    artifact.captured_sink_effects = M.copy_value(captured_sink_effects)
  end
  return artifact
end

function M.admission_trace_output_path(filename)
  if type(filename) ~= "string"
    or filename:match("^[A-Za-z0-9][A-Za-z0-9._-]*$") == nil then
    error("testkit-internal: r9-trace-output-filename-invalid: R9 admission trace output filename is invalid", 0)
  end
  local root = os.getenv("FKST_R9_TRACE_ROOT") or os.getenv("FKST_RUNTIME_ROOT")
  if type(root) ~= "string" or root == "" or root:find("[\r\n]") ~= nil then
    error("testkit-internal: r9-trace-output-root-invalid: R9 admission trace output root is invalid", 0)
  end
  return root:gsub("/+$", "") .. "/" .. filename
end

local R11_CAUSE = "R11.queue_dialogue_to_sync_consensus_call"
local R11_MANIFEST_PATH = "migration/intent-diffs/2775.json"
local R11_DELIVERY_ATOMS = {
  ["queue:consensus.proposal"] = true,
  ["queue:consensus.consensus_reached"] = true,
  ["queue:consensus.consensus_converge"] = true,
  ["raise:devloop_consensus_request"] = true,
  ["raise:devloop_consensus_continue"] = true,
  ["call:consensus.reach"] = true,
}

local function sorted_unique_strings(values, label)
  if not M.is_json_array(values) then
    error(label .. " must be a JSON array", 0)
  end
  local seen = {}
  local prior = nil
  for _, value in ipairs(values) do
    if type(value) ~= "string" or value == "" then
      error(label .. " must contain non-empty strings", 0)
    end
    if value:find("*", 1, true) or value:find("?", 1, true)
      or value:find("[", 1, true) or value:find("]", 1, true) then
      error(label .. " must not contain wildcard atoms", 0)
    end
    if seen[value] then
      error(label .. " must not contain duplicate values: " .. value, 0)
    end
    if prior ~= nil and prior > value then
      error(label .. " must be byte-sorted", 0)
    end
    seen[value] = true
    prior = value
  end
  return seen
end

local function delivery_authorizations(manifest)
  if type(manifest) ~= "table" or manifest.cause ~= R11_CAUSE then
    error("R11 OLD observation comparison requires the committed R11 manifest", 0)
  end
  local changed = {}
  for _, field in ipairs({ "changed_row_ids", "changed_edge_ids", "changed_policy_ids" }) do
    local ids = sorted_unique_strings(manifest[field], "R11 manifest " .. field)
    for observation_id in pairs(ids) do
      if changed[observation_id] then
        error("R11 manifest observation ID appears in multiple changed-ID sets: " .. observation_id, 0)
      end
      changed[observation_id] = true
    end
  end

  if not M.is_json_array(manifest.authorized_delivery_atoms) then
    error("R11 manifest authorized_delivery_atoms must be a JSON array", 0)
  end
  local authorizations = {}
  local prior = nil
  for index, entry in ipairs(manifest.authorized_delivery_atoms) do
    if type(entry) ~= "table" then
      error("R11 delivery authorization must be an object at index " .. tostring(index), 0)
    end
    local keys = {}
    for key in pairs(entry) do keys[key] = true end
    if not keys.observation_id or not keys.remove or not keys.add then
      error("R11 delivery authorization requires observation_id/remove/add", 0)
    end
    for key in pairs(keys) do
      if key ~= "observation_id" and key ~= "remove" and key ~= "add" then
        error("R11 delivery authorization has unsupported field: " .. tostring(key), 0)
      end
    end
    local observation_id = entry.observation_id
    if type(observation_id) ~= "string" or observation_id == "" then
      error("R11 delivery authorization observation_id must be a non-empty string", 0)
    end
    if prior ~= nil and prior > observation_id then
      error("R11 delivery authorizations must be byte-sorted by observation_id", 0)
    end
    if authorizations[observation_id] then
      error("R11 delivery authorization is duplicated: " .. observation_id, 0)
    end
    local removed = sorted_unique_strings(entry.remove, observation_id .. " remove")
    local added = sorted_unique_strings(entry.add, observation_id .. " add")
    for atom in pairs(removed) do
      if not R11_DELIVERY_ATOMS[atom] or atom:sub(1, 6) ~= "queue:" then
        error("R11 manifest cannot authorize removed non-delivery atom: " .. atom, 0)
      end
    end
    for atom in pairs(added) do
      if not R11_DELIVERY_ATOMS[atom]
        or (atom:sub(1, 6) ~= "raise:" and atom:sub(1, 5) ~= "call:") then
        error("R11 manifest cannot authorize added non-delivery atom: " .. atom, 0)
      end
    end
    if removed["queue:consensus.consensus_converge"]
      and added["call:consensus.reach"] then
      added["call:consensus.reach"] = nil
      added["raise:devloop_consensus_continue"] = true
      if removed["queue:consensus.proposal"] then
        added["raise:devloop_consensus_request"] = true
      end
    end
    if observation_id == "grantless-sink-pr-exact-set"
      and removed["queue:consensus.proposal"] then
      added["raise:devloop_consensus_request"] = true
    end
    authorizations[observation_id] = { remove = removed, add = added }
    prior = observation_id
  end
  for observation_id in pairs(changed) do
    if not authorizations[observation_id] then
      error("R11 changed observation lacks delivery authorization: " .. observation_id, 0)
    end
  end
  for observation_id in pairs(authorizations) do
    if not changed[observation_id] then
      error("R11 delivery authorization is not listed in changed-ID sets: " .. observation_id, 0)
    end
  end
  return authorizations
end

local function delivery_atom(value, role)
  if type(value) ~= "string" then return nil end
  local surface = value
  if surface == "call:consensus.reach" then
    return surface
  end
  for _, candidate in ipairs({
    "consensus.consensus_converge",
    "consensus.consensus_reached",
    "consensus.proposal",
    "devloop_consensus_continue",
    "devloop_consensus_request",
    "devloop_issue_decision",
    "devloop_review_continue",
    "devloop_review_request",
    "devloop_review_decision",
  }) do
    if surface:sub(-#candidate) == candidate then
      surface = candidate
      break
    end
  end
  if surface:sub(1, 9) == "consumes:" then
    surface = surface:sub(10)
    role = "consumer"
  elseif surface:sub(1, 6) == "queue:" then
    surface = surface:sub(7)
  end
  surface = surface:gsub("^github%-devloop%.", "")
  surface = surface:gsub("^github%-devloop%-pr%.", "")

  if surface == "consensus.proposal" then
    return "queue:consensus.proposal"
  end
  if surface == "consensus.consensus_reached" then
    return "queue:consensus.consensus_reached"
  end
  if surface == "consensus.consensus_converge" then
    return "queue:consensus.consensus_converge"
  end
  if surface == "devloop_consensus_request" or surface == "devloop_review_request" then
    return role == "consumer" and "call:consensus.reach" or "raise:devloop_consensus_request"
  end
  if surface == "devloop_consensus_continue" or surface == "devloop_review_continue" then
    return "raise:devloop_consensus_continue"
  end
  if surface == "devloop_issue_decision" or surface == "devloop_review_decision" then
    return "call:consensus.reach"
  end
  return nil
end

local function normalize_delivery_field(container, key, role, atoms)
  if type(container) ~= "table" then return false end
  local atom = delivery_atom(container[key], role)
  if atom == nil then return false end
  atoms[atom] = true
  container[key] = "<R11-delivery>"
  return true
end

local function normalize_source_positions(projection)
  for _, evidence in ipairs((projection or {}).evidence_refs or {}) do
    if type(evidence.ref) == "string" then
      evidence.ref = evidence.ref:gsub("(%.lua):%d+$", "%1:<line>")
    end
  end
end

local function project_old_behavior_record(record)
  local projection = M.copy_value(record)
  local atoms = {}
  local boundary = tostring(projection.boundary or "")
  local consumer_role = boundary == "entry_acceptor" and "consumer" or "producer"

  local site = projection.site or {}
  normalize_delivery_field(site, "ordinal", consumer_role, atoms)
  local intent = projection.typed_intent or {}
  normalize_delivery_field(intent, "source_boundary", "consumer", atoms)
  normalize_delivery_field(intent, "target", consumer_role, atoms)

  for _, evidence in ipairs(projection.evidence_refs or {}) do
    local role = evidence.kind == "runtime-event-source" and "consumer" or "producer"
    normalize_delivery_field(evidence, "ref", role, atoms)
  end

  local outcome = projection.old_outcome or {}
  local observation_id = tostring(projection.observation_id or "")
  local sink_catalog = boundary == "effect_sink"
    or observation_id:find("grantless-sink-", 1, true) == 1
  local writes = M.json_array()
  for _, write in ipairs(outcome.observable_writes or {}) do
    local projected = M.copy_value(write)
    local effect_atom = delivery_atom(projected.effect_id, "producer")
    local queue_atom = delivery_atom(projected.queue, "producer")
    if effect_atom then atoms[effect_atom] = true end
    if queue_atom then atoms[queue_atom] = true end
    if not sink_catalog or (effect_atom == nil and queue_atom == nil) then
      if effect_atom then projected.effect_id = "<R11-delivery>" end
      if queue_atom then projected.queue = "<R11-delivery>" end
      table.insert(writes, projected)
    end
  end
  outcome.observable_writes = writes

  local effects = M.json_array()
  for _, effect in ipairs(outcome.emitted_effects or {}) do
    local projected = M.copy_value(effect)
    normalize_delivery_field(projected, "effect_id", "producer", atoms)
    table.insert(effects, projected)
  end
  outcome.emitted_effects = effects

  if sink_catalog and type(projection.old_inputs) == "table"
    and type(projection.old_inputs.current_fact) == "table"
    and projection.old_inputs.current_fact.record_count ~= nil then
    projection.old_inputs.current_fact.record_count = #writes
  end
  return projection, atoms
end

local function exact_set_difference(actual, expected)
  local missing = {}
  local extra = {}
  for value in pairs(expected) do
    if not actual[value] then table.insert(missing, value) end
  end
  for value in pairs(actual) do
    if not expected[value] then table.insert(extra, value) end
  end
  table.sort(missing)
  table.sort(extra)
  if #missing == 0 and #extra == 0 then return nil end
  return "missing=[" .. table.concat(missing, ",") .. "] extra=[" .. table.concat(extra, ",") .. "]"
end

local function index_records(records, label)
  if not M.is_json_array(records) then error(label .. " must be a JSON array", 0) end
  local indexed = {}
  for _, record in ipairs(records) do
    local observation_id = type(record) == "table" and record.observation_id or nil
    if type(observation_id) ~= "string" or observation_id == "" then
      error(label .. " contains a record without observation_id", 0)
    end
    if indexed[observation_id] then error(label .. " duplicates " .. observation_id, 0) end
    indexed[observation_id] = record
  end
  return indexed
end

function M.assert_delivery_atom_pair(actual, expected, observation_id, context, manifest)
  local authorization_manifest = manifest or json.decode(file.read(R11_MANIFEST_PATH))
  local authorization = delivery_authorizations(authorization_manifest)[observation_id]
  if authorization == nil then
    error(tostring(context) .. " has no R11 delivery authorization for " .. observation_id, 0)
  end
  local actual_atom = delivery_atom(actual, "producer")
  local expected_atom = delivery_atom(expected, "producer")
  local removed = {}
  local added = {}
  if expected_atom ~= nil and expected_atom ~= actual_atom then removed[expected_atom] = true end
  if actual_atom ~= nil and actual_atom ~= expected_atom then added[actual_atom] = true end
  local removed_difference = exact_set_difference(removed, authorization.remove)
  local added_difference = exact_set_difference(added, authorization.add)
  if removed_difference or added_difference then
    error(tostring(context) .. " delivery atom pair differs for " .. observation_id
      .. " remove{" .. tostring(removed_difference or "exact") .. "}"
      .. " add{" .. tostring(added_difference or "exact") .. "}", 0)
  end
end

function M.assert_delivery_scoped_admission_fixture(actual, expected, observation_id, context, manifest)
  local actual_projection = M.copy_value(actual)
  local expected_projection = M.copy_value(expected)
  if #actual_projection.granted_effect_ids ~= #expected_projection.granted_effect_ids then
    error(tostring(context) .. " granted effect multiplicity differs", 0)
  end
  for ordinal, actual_effect_id in ipairs(actual_projection.granted_effect_ids) do
    local expected_effect_id = expected_projection.granted_effect_ids[ordinal]
    if actual_effect_id ~= expected_effect_id then
      M.assert_delivery_atom_pair(actual_effect_id, expected_effect_id, observation_id,
        tostring(context) .. " granted effect " .. tostring(ordinal), manifest)
      actual_projection.granted_effect_ids[ordinal] = "<R11-delivery>"
      expected_projection.granted_effect_ids[ordinal] = "<R11-delivery>"
    end
  end
  if #actual_projection.observable_writes ~= #expected_projection.observable_writes then
    error(tostring(context) .. " observable write multiplicity differs", 0)
  end
  for ordinal, actual_write in ipairs(actual_projection.observable_writes) do
    local expected_write = expected_projection.observable_writes[ordinal]
    if actual_write.effect_id ~= expected_write.effect_id then
      M.assert_delivery_atom_pair(actual_write.effect_id, expected_write.effect_id, observation_id,
        tostring(context) .. " observable write " .. tostring(ordinal), manifest)
      actual_write.effect_id = "<R11-delivery>"
      expected_write.effect_id = "<R11-delivery>"
    end
  end
  local difference = M.first_difference(actual_projection, expected_projection, tostring(context))
  if difference ~= nil or M.canonical_json(actual_projection) ~= M.canonical_json(expected_projection) then
    error(tostring(context) .. " product projection or non-delivery field differs at "
      .. tostring(difference or "canonical-json"), 0)
  end
end

function M.assert_old_behavior_records(actual, expected, context, manifest)
  local authorization_manifest = manifest or json.decode(file.read(R11_MANIFEST_PATH))
  local authorizations = delivery_authorizations(authorization_manifest)
  local actual_records = index_records(actual, "runtime OLD observations")
  local expected_records = index_records(expected, "committed OLD observations")
  local all_ids = {}
  for observation_id in pairs(actual_records) do all_ids[observation_id] = true end
  for observation_id in pairs(expected_records) do all_ids[observation_id] = true end
  for observation_id in pairs(all_ids) do
    local runtime_record = actual_records[observation_id]
    local committed_record = expected_records[observation_id]
    if runtime_record == nil or committed_record == nil then
      error(tostring(context) .. " observation membership differs at " .. observation_id, 0)
    end
    local authorization = authorizations[observation_id]
    if authorization == nil then
      local difference = M.first_difference(runtime_record, committed_record, observation_id)
      if difference ~= nil or M.canonical_json(runtime_record) ~= M.canonical_json(committed_record) then
        error(tostring(context) .. " unlisted observation differs at "
          .. tostring(difference or observation_id), 0)
      end
    else
      local runtime_product, runtime_atoms = project_old_behavior_record(runtime_record)
      local committed_product, committed_atoms = project_old_behavior_record(committed_record)
      -- A source line number is positional metadata, not a product outcome: authorized R11
      -- edits shift statements within a file without changing behavior. Normalize only the
      -- line, keeping the file path exact, and only for manifest-authorized observations.
      normalize_source_positions(runtime_product)
      normalize_source_positions(committed_product)
      local difference = M.first_difference(runtime_product, committed_product, observation_id .. ".product")
      if difference ~= nil or M.canonical_json(runtime_product) ~= M.canonical_json(committed_product) then
        error(tostring(context) .. " product projection differs at "
          .. tostring(difference or observation_id), 0)
      end
      local removed = {}
      local added = {}
      for atom in pairs(committed_atoms) do if not runtime_atoms[atom] then removed[atom] = true end end
      for atom in pairs(runtime_atoms) do if not committed_atoms[atom] then added[atom] = true end end
      local removed_difference = exact_set_difference(removed, authorization.remove)
      local added_difference = exact_set_difference(added, authorization.add)
      if removed_difference or added_difference then
        error(tostring(context) .. " delivery diff differs for " .. observation_id
          .. " remove{" .. tostring(removed_difference or "exact") .. "}"
          .. " add{" .. tostring(added_difference or "exact") .. "}", 0)
      end
    end
  end
end

return M
