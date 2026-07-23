local observation = require("testkit_internal.old_behavior_observation_support")
local owner_projection = require("devloop.restart_owner_pending_projection")
local restart_obligations = require("devloop.restart_obligations")
local restart_trace = require("devloop.restart_trace")
local trace_derivation = require("devloop.restart_trace_derivation")
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

local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}

local function is_frozen_record(record)
  local site = type(record) == "table" and record.site or nil
  return type(site) == "table"
    and site.path == SITE.path
    and site.symbol == SITE.symbol
    and site.ordinal == SITE.ordinal
    and record.old_outcome.reason_code == "apply"
end

local function frozen_record()
  local inventory = json.decode(file.read(CORPUS_PATH))
  local selected = nil
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if is_frozen_record(record) then
      t.eq(selected, nil, "single frozen apply witness")
      selected = record
    end
  end
  t.is_true(selected ~= nil, "frozen review reconcile apply witness")
  return selected
end

local function canonical_edge()
  local edges = owner_projection.edges(
    OWNER,
    h.core.restart_transition_table(),
    inventories
  )
  for _, edge in ipairs(edges) do
    if edge.id == EDGE_ID then
      return edge, edges
    end
  end
  error("restart CAS trace generator: review reconcile edge is missing", 0)
end

local function frozen_effect_ids(record)
  local result = restart_trace.array()
  for _, write in ipairs(record.old_outcome.observable_writes or {}) do
    table.insert(result, write.queue)
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

local function actual_trace(edge, record, snapshot, decision, writes, fingerprint, terminal_why)
  return restart_trace.define({
    schema = "restart-trace.v1",
    owner = OWNER,
    fixture_id = record.old_outcome.reason_code,
    steps = restart_trace.array({
      {
        edge_id = decision.edge_id,
        row_replay_id = NULL,
        kind = edge.kind,
        source = {
          state = observation.nullable(edge.source.state),
          boundary = observation.nullable(edge.source.boundary),
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
          current_version = snapshot.current.version,
          incoming_version = decision.incoming_version,
          generation = snapshot.generation,
          lock_epoch = snapshot.lock_epoch,
        },
        grant_fingerprint = fingerprint,
        effect_entitlement_id = decision.effect_entitlement_id or NULL,
        effect_ids = restart_trace.array(decision.granted_effect_ids),
        queue = edge.source.boundary,
        payload_obligations = payload_obligations(decision.granted_effect_ids),
        observable_writes = writes,
        terminal_why = terminal_why,
      },
    }),
  })
end

return {
  test_pr_owner_derives_and_executes_cas_admission_restart_trace = function()
    local record = frozen_record()
    local edge, edges = canonical_edge()
    local source_witness = require("core.restart.review_reconcile_obligations")[1]
    local result = restart_obligations.derive(edges, { [edge.id] = source_witness })
    t.eq(#result.obligations, 1, "PR owner CAS-admission obligation count")
    local obligation = result.obligations[1]
    local current = record.old_inputs.current_fact
    local reconcile = h.review_reconcile()
    local effect_ids = frozen_effect_ids(record)
    local witness = {
      owner = OWNER,
      edge_id = edge.id,
      input_fixture_id = record.old_outcome.reason_code,
      witness_id = source_witness.witness_id,
      expected_decision = {
        cas_status = obligation.expected_decision.cas_status,
        reason_code = obligation.expected_decision.reason_code,
        cas_outcome = obligation.expected_decision.cas_outcome,
      },
      expected_effect_ids = effect_ids,
      expected_payload_obligations = restart_trace.array(
        source_witness.expected_payload_obligations
      ),
      trace = {
        snapshot_fingerprint = "r9-pr-review-reconcile|apply",
        generation_epoch = {
          current_version = current.version,
          incoming_version = record.old_inputs.incoming_version,
          generation = current.version,
          lock_epoch = "r9-pr-review-reconcile@" .. current.version,
        },
        effect_entitlement_id = record.old_outcome.status == "apply"
          and edge.transition_effect_entitlements.apply.id or NULL,
        queue = edge.source.boundary,
        observable_writes = frozen_trace_writes(record),
        terminal_why = { terminal_cause = reconcile.terminal_cause },
        frozen_observation = {
          id = record.observation_id,
          status = record.old_outcome.status,
          reason_code = record.old_outcome.reason_code,
          cas_outcome = record.old_outcome.cas_outcome,
        },
      },
    }
    local expected = trace_derivation.derive_cas_admission(edge, obligation, witness)

    local snapshot = restart_effects.seal_snapshot({
      owner = OWNER,
      entity = { kind = "pr", repo = "owner/repo", number = 7 },
      proposal_id = reconcile.proposal_id,
      current = { state = current.state, version = current.version },
      snapshot_fingerprint = witness.trace.snapshot_fingerprint,
      lock_epoch = witness.trace.generation_epoch.lock_epoch,
      generation = witness.trace.generation_epoch.generation,
    })
    local decision = restart_effects.decide_transition(snapshot, {
      semantic_variant = "review_reconcile_true_stall",
      source_boundary = "devloop_review_reconcile",
      target = "blocked",
      incoming_version = record.old_inputs.incoming_version,
      target_version = nil,
      overlay_version = record.old_inputs.incoming_version,
    })
    local grant = restart_effects.mint_grant(
      snapshot,
      decision,
      "comment:pr:reconcile-blocked"
    )
    t.is_true(grant ~= nil, "real PR grant minted")
    local facade = restart_effect_facade.make({
      family = "pr-review-reconcile",
      verify_grant = restart_effects.verify_grant,
      sink_inventory = require("core.restart.sink_inventory"),
    })
    local emit_args = {
      core = h.core,
      repo = "owner/repo",
      issue_number = "42",
      reconcile = reconcile,
      action = "drop",
      reason = tostring(reconcile.terminal_cause)
        .. "-after-" .. tostring(reconcile.round) .. "-review-rounds",
      version = decision.incoming_version,
    }
    local writes = restart_trace.array()
    for ordinal, effect_id in ipairs(decision.granted_effect_ids) do
      local emitted, rejection = facade.emit(grant, effect_id, snapshot, emit_args)
      t.is_true(emitted ~= nil, "real PR facade effect " .. tostring(rejection))
      table.insert(writes, observation.admission_trace_write(
        ordinal,
        effect_id,
        emitted,
        "actual PR generator trace"
      ))
    end
    local fingerprint = restart_trace.grant_fingerprint({
      snapshot_fingerprint = snapshot.snapshot_fingerprint,
      edge_id = decision.edge_id,
      effect_entitlement_id = decision.effect_entitlement_id,
    })
    local actual = actual_trace(
      edge,
      record,
      snapshot,
      decision,
      writes,
      fingerprint,
      { terminal_cause = reconcile.terminal_cause }
    )

    t.eq(
      observation.canonical_json(actual),
      observation.canonical_json(expected),
      "PR actual equals R5-derived expected byte-exact"
    )
    local encoded = observation.canonical_json(expected)
    t.eq(encoded:find('"grant":', 1, true), nil, "no serialized grant")
    t.eq(encoded:find('"seal', 1, true), nil, "no serialized seal")
  end,
}
