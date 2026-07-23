local observation = require("testkit_internal.old_behavior_observation_support")
local restart_trace = require("devloop.restart_trace")
local expected_traces = require("core.restart.review_reconcile_traces")
local obligations = require("core.restart.review_reconcile_obligations")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local h = require("tests.devloop_helpers")

local t = h.t
local NULL = restart_trace.null
local OWNER = "github-devloop-pr"
local EDGE_ID = OWNER .. "/reviewing/entry/review_reconcile_true_stall"
local CORPUS_PATH = "migration/restart-lifecycle.inventory.json"
local SITE = {
  path = "packages/github-devloop-pr/departments/reconcile/main.lua",
  symbol = "pipeline_review",
  ordinal = "versioned_transition_status:reviewing->blocked",
}

local function is_frozen_record(record)
  local site = type(record) == "table" and record.site or nil
  return type(site) == "table"
    and site.path == SITE.path
    and site.symbol == SITE.symbol
    and site.ordinal == SITE.ordinal
end

local function frozen_records()
  local inventory = json.decode(file.read(CORPUS_PATH))
  local records = restart_trace.array()
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if is_frozen_record(record) then
      table.insert(records, record)
    end
  end
  table.sort(records, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  return records
end

local function index_by(values, field)
  local result = {}
  for _, value in ipairs(values) do
    result[value[field]] = value
  end
  return result
end

local function index_records(records)
  local result = {}
  for _, record in ipairs(records) do
    result[record.old_outcome.reason_code] = record
  end
  return result
end

local function review_reconcile_edge()
  local edges = owner_pending_projection.edges(
    OWNER,
    h.core.restart_transition_table(),
    {
      canonicalization = require("core.restart.canonicalization_inventory"),
      entry = require("core.restart.entry_inventory"),
      operator_reentry = require("core.restart.operator_reentry_inventory"),
    }
  )
  for _, edge in ipairs(edges) do
    if edge.id == EDGE_ID then
      return edge
    end
  end
  error("restart review reconcile trace: entry edge is missing", 0)
end

local function payload_obligations(effect_ids)
  local result = restart_trace.array()
  for _, effect_id in ipairs(effect_ids or {}) do
    table.insert(result, {
      effect_id = effect_id,
      equality = "byte-exact-frozen-old",
    })
  end
  return result
end

local function frozen_full_writes(record)
  local result = restart_trace.array()
  for _, write in ipairs(record.old_outcome.observable_writes or {}) do
    table.insert(result, { queue = write.queue, payload = write.payload })
  end
  return result
end

local function frozen_trace_writes(record)
  local result = restart_trace.array()
  for ordinal, write in ipairs(record.old_outcome.observable_writes or {}) do
    table.insert(result, observation.admission_trace_write(
      ordinal,
      write.queue,
      write.payload,
      record.observation_id
    ))
  end
  return result
end

local function actual_case(record, edge)
  local current = record.old_inputs.current_fact
  local fixture_id = record.old_outcome.reason_code
  local reconcile = h.review_reconcile()
  t.eq(record.old_inputs.incoming_version,
    reconcile.issue_version .. "/review-loop/" .. tostring(reconcile.round))

  local snapshot = restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "pr", repo = "owner/repo", number = 7 },
    proposal_id = reconcile.proposal_id,
    current = { state = current.state, version = current.version },
    snapshot_fingerprint = "r9-pr-review-reconcile|" .. fixture_id,
    lock_epoch = "r9-pr-review-reconcile@" .. current.version,
    generation = current.version,
  })
  local decision = restart_effects.decide_transition(snapshot, {
    semantic_variant = "review_reconcile_true_stall",
    source_boundary = "devloop_review_reconcile",
    target = "blocked",
    incoming_version = record.old_inputs.incoming_version,
    target_version = nil,
    overlay_version = record.old_inputs.incoming_version,
  })

  local writes = restart_trace.array()
  local full_writes = restart_trace.array()
  local grant_fingerprint = NULL
  local terminal_why = NULL
  if decision.status == "apply" then
    local grant = restart_effects.mint_grant(
      snapshot,
      decision,
      "comment:pr:reconcile-blocked"
    )
    t.is_true(grant ~= nil, fixture_id .. ": actual grant minted")
    local facade = restart_effect_facade.make({
      family = "pr-review-reconcile",
      verify_grant = restart_effects.verify_grant,
      sink_inventory = require("core.restart.sink_inventory"),
    })
    local args = {
      core = h.core,
      repo = "owner/repo",
      issue_number = "42",
      reconcile = reconcile,
      action = "drop",
      reason = tostring(reconcile.terminal_cause)
        .. "-after-" .. tostring(reconcile.round) .. "-review-rounds",
      version = decision.incoming_version,
    }
    for ordinal, effect_id in ipairs(decision.granted_effect_ids) do
      local emitted, rejection = facade.emit(grant, effect_id, snapshot, args)
      t.is_true(emitted ~= nil, fixture_id .. ": actual effect " .. tostring(rejection))
      table.insert(writes, observation.admission_trace_write(
        ordinal,
        effect_id,
        emitted,
        fixture_id .. ": actual restart trace"
      ))
      table.insert(full_writes, { queue = effect_id, payload = emitted })
    end
    grant_fingerprint = restart_trace.grant_fingerprint({
      snapshot_fingerprint = snapshot.snapshot_fingerprint,
      edge_id = decision.edge_id,
      effect_entitlement_id = decision.effect_entitlement_id,
    })
    terminal_why = { terminal_cause = reconcile.terminal_cause }
  end

  local trace = restart_trace.define({
    schema = "restart-trace.v1",
    owner = OWNER,
    fixture_id = fixture_id,
    steps = restart_trace.array({
      {
        edge_id = decision.edge_id,
        row_replay_id = NULL,
        kind = edge.kind,
        source = {
          state = edge.source.state,
          boundary = edge.source.boundary,
        },
        target = edge.target,
        cause_evidence = {
          source_boundary = edge.source.boundary,
          frozen_observation_id = record.observation_id,
          frozen_status = record.old_outcome.status,
          frozen_reason_code = record.old_outcome.reason_code,
          frozen_cas_outcome = record.old_outcome.cas_outcome,
        },
        cas_policy_id = decision.cas_policy_id,
        cas_status = decision.status,
        reason_code = decision.reason_code,
        cas_outcome = decision.cas_outcome,
        pending_status = edge.pending_order.participates and "included" or "excluded",
        generation_epoch = {
          current_version = current.version,
          incoming_version = record.old_inputs.incoming_version,
          generation = snapshot.generation,
          lock_epoch = snapshot.lock_epoch,
        },
        grant_fingerprint = grant_fingerprint,
        effect_entitlement_id = decision.effect_entitlement_id or NULL,
        effect_ids = restart_trace.array(decision.granted_effect_ids),
        queue = edge.source.boundary,
        payload_obligations = payload_obligations(decision.granted_effect_ids),
        observable_writes = writes,
        terminal_why = terminal_why,
      },
    }),
  })
  return trace, full_writes
end

return {
  test_review_reconcile_restart_traces_match_pr_authority_facade_and_frozen_old = function()
    local records = frozen_records()
    local frozen = index_records(records)
    local expected = index_by(expected_traces, "fixture_id")
    local actual = {}
    local full_writes = {}
    local edge = review_reconcile_edge()

    for _, record in ipairs(records) do
      local fixture_id = record.old_outcome.reason_code
      actual[fixture_id], full_writes[fixture_id] = actual_case(record, edge)
    end

    t.eq(#records, 4, "review reconcile frozen OLD observation count")
    t.eq(#expected_traces, #records)
    for _, obligation in ipairs(obligations) do
      local fixture_id = obligation.input_fixture_id
      local record = frozen[fixture_id]
      local expected_trace = expected[fixture_id]
      local actual_trace = actual[fixture_id]
      t.is_true(record ~= nil, fixture_id .. ": frozen record")
      t.is_true(expected_trace ~= nil, fixture_id .. ": expected trace")
      t.is_true(actual_trace ~= nil, fixture_id .. ": actual trace")
      local expected_step = expected_trace.steps[1]
      t.eq(expected_step.cause_evidence.frozen_observation_id, record.observation_id)
      t.eq(expected_step.cause_evidence.frozen_status, record.old_outcome.status)
      t.eq(expected_step.cause_evidence.frozen_reason_code, record.old_outcome.reason_code)
      t.eq(expected_step.cause_evidence.frozen_cas_outcome, record.old_outcome.cas_outcome)
      t.eq(
        observation.canonical_json(expected_step.observable_writes),
        observation.canonical_json(frozen_trace_writes(record)),
        fixture_id .. ": expected writes project frozen OLD byte-exact"
      )
      t.eq(
        observation.canonical_json(full_writes[fixture_id]),
        observation.canonical_json(frozen_full_writes(record)),
        fixture_id .. ": facade payloads equal frozen OLD byte-exact"
      )
      t.eq(
        observation.canonical_json(actual_trace),
        observation.canonical_json(expected_trace),
        fixture_id .. ": actual restart trace equals expected byte-exact"
      )
      local encoded = observation.canonical_json(actual_trace)
      t.eq(encoded:find('"grant":', 1, true), nil, fixture_id .. ": no serialized grant")
      t.eq(encoded:find('"seal', 1, true), nil, fixture_id .. ": no serialized seal")
    end
  end,
}
