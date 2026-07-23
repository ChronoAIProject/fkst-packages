local observation = require("testkit_internal.old_behavior_observation_support")
local restart_edges = require("devloop.restart_edges")
local restart_trace = require("devloop.restart_trace")
local expected_traces = require("core.restart.timeout_traces")
local obligations = require("core.restart.timeout_obligations")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local transition_version = require("contract.transition_version")
local conv_reconcile = require("devloop.convergence.reconcile")
local h = require("tests.devloop_core_helpers")

local t = h.t
local core = h.core
local NULL = restart_trace.null
local CORPUS_PATH = "migration/intent_bounded_replay/corpus/timeout-reconcile.json"

local function index_by(values, field)
  local result = {}
  for _, value in ipairs(values) do
    result[value[field]] = value
  end
  return result
end

local function timeout_edge()
  for _, edge in ipairs(restart_edges.extract_timeout_edges(
    core.restart_package_name,
    core.restart_transition_table()
  )) do
    if edge.id == "github-devloop/ready/timeout/actionable_kickoff_timeout" then
      return edge
    end
  end
  error("restart timeout trace: timeout edge is missing", 0)
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

local V_OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local READY_ATTEMPT = transition_version.timeout_at(V_EQUAL, "ready", 3)

local function timeout_reconcile_version(version)
  return conv_reconcile.timeout_reconcile_state_version(version, "ready", 3)
end

local inputs = {
  ["newer-source-marker-missing-pending"] = {
    current = { state = nil, version = nil },
    incoming_version = timeout_reconcile_version(
      transition_version.timeout_at(V_NEWER, "ready", 3)
    ),
  },
  ["source-equal-apply"] = {
    current = { state = "ready", version = READY_ATTEMPT },
    incoming_version = timeout_reconcile_version(READY_ATTEMPT),
  },
  ["source-older-stale"] = {
    current = { state = "ready", version = READY_ATTEMPT },
    incoming_version = timeout_reconcile_version(
      transition_version.timeout_at(V_OLDER, "ready", 3)
    ),
  },
}

local function actual_writes(fixture_id, snapshot, decision, input)
  local writes = restart_trace.array()
  if decision.status ~= "apply" then
    return writes, NULL, NULL
  end

  local grant = restart_effects.mint_grant(
    snapshot,
    decision,
    "comment:issue:timeout-reconcile"
  )
  t.is_true(grant ~= nil, fixture_id .. ": actual grant minted")
  local facade = restart_effect_facade.make({
    family = "timeout-reconcile",
    verify_grant = restart_effects.verify_grant,
    sink_inventory = require("core.restart.sink_inventory"),
  })
  local source_ref = { kind = "external", ref = "owner/repo#issue/42" }
  local args = {
    issue = { repo = "owner/repo", number = "42" },
    reconcile = {
      proposal_id = "github-devloop/issue/owner/repo/42",
      issue_version = READY_ATTEMPT,
      state = "ready",
      round = 3,
      dedup_key = "timeout-reconcile-fixture:" .. fixture_id,
      source_ref = source_ref,
    },
    action = "drop",
    reason = "state-output-obligation-timeout-after-3-attempts",
    state_version = input.incoming_version,
    why_fields = {
      from_state = "ready",
      from_version = READY_ATTEMPT,
      terminal_version = input.incoming_version,
      reason_class = "state-output-obligation-timeout",
      source_ref = source_ref,
    },
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
  end
  return writes, restart_trace.grant_fingerprint({
    snapshot_fingerprint = snapshot.snapshot_fingerprint,
    edge_id = decision.edge_id,
    effect_entitlement_id = decision.effect_entitlement_id,
  }), {
    reason_class = args.why_fields.reason_class,
  }
end

local function actual_traces(corpus)
  local edge = timeout_edge()
  local traces = restart_trace.array()
  for _, fixture in ipairs(corpus.fixtures) do
    local input = inputs[fixture.fixture_id]
    t.is_true(input ~= nil, fixture.fixture_id .. ": actual input fixture")
    local snapshot = restart_effects.seal_snapshot({
      owner = corpus.owner,
      entity = { kind = "issue", repo = "owner/repo", number = 42 },
      proposal_id = "github-devloop/issue/owner/repo/42",
      current = input.current,
      snapshot_fingerprint = "r9-timeout-reconcile:" .. fixture.fixture_id,
      lock_epoch = "r9-timeout-reconcile:lock",
      generation = "r9-timeout-reconcile:generation",
    })
    local decision = restart_effects.decide_transition(snapshot, {
      semantic_variant = "actionable_kickoff_timeout",
      target = "blocked",
      incoming_version = input.incoming_version,
    })
    local writes, grant_fingerprint, terminal_why = actual_writes(
      fixture.fixture_id,
      snapshot,
      decision,
      input
    )
    table.insert(traces, restart_trace.define({
      schema = "restart-trace.v1",
      owner = corpus.owner,
      fixture_id = fixture.fixture_id,
      steps = restart_trace.array({
        {
          edge_id = decision.edge_id,
          row_replay_id = NULL,
          kind = edge.kind,
          source = { state = edge.source.state, boundary = NULL },
          target = edge.target,
          cause_evidence = {
            timeout_evidence_policy_id = edge.timeout_evidence_policy_id,
          },
          cas_policy_id = decision.cas_policy_id,
          cas_status = decision.status,
          reason_code = decision.reason_code,
          cas_outcome = decision.cas_outcome,
          pending_status = edge.pending_order.participates and "included" or "excluded",
          generation_epoch = {
            current_version = observation.nullable(input.current.version),
            incoming_version = input.incoming_version,
            generation = snapshot.generation,
            lock_epoch = snapshot.lock_epoch,
          },
          grant_fingerprint = grant_fingerprint,
          effect_entitlement_id = decision.effect_entitlement_id or NULL,
          effect_ids = restart_trace.array(decision.granted_effect_ids),
          queue = "devloop_timeout_reconcile",
          payload_obligations = payload_obligations(decision.granted_effect_ids),
          observable_writes = writes,
          terminal_why = terminal_why,
        },
      }),
    }))
  end
  return traces
end

local function assert_rejected(value, context)
  local ok = pcall(restart_trace.define, value)
  t.eq(ok, false, context)
end

return {
  test_restart_trace_schema_rejects_missing_unknown_and_secret_authority_fields = function()
    local base = observation.copy_value(expected_traces[2])
    local missing = observation.copy_value(base)
    missing.steps[1].pending_status = nil
    assert_rejected(missing, "missing required field")

    local unknown = observation.copy_value(base)
    unknown.steps[1].unexpected = true
    assert_rejected(unknown, "unknown step field")

    local serialized_grant = observation.copy_value(base)
    serialized_grant.steps[1].grant = { token = "opaque" }
    assert_rejected(serialized_grant, "serialized grant")

    local serialized_seal = observation.copy_value(base)
    serialized_seal.steps[1].cause_evidence.owner_seal = "opaque"
    assert_rejected(serialized_seal, "serialized seal")

    local secret_fingerprint = observation.copy_value(base)
    secret_fingerprint.steps[1].grant_fingerprint = "secret-token"
    assert_rejected(secret_fingerprint, "non-secret fingerprint contract")
  end,

  test_timeout_restart_traces_match_actual_execution_and_frozen_corpus_byte_exact = function()
    local corpus = json.decode(file.read(CORPUS_PATH))
    local frozen = index_by(corpus.fixtures, "fixture_id")
    local expected = index_by(expected_traces, "fixture_id")
    local actual = index_by(actual_traces(corpus), "fixture_id")
    t.eq(#expected_traces, #corpus.fixtures)

    for _, obligation in ipairs(obligations) do
      local fixture_id = obligation.input_fixture_id
      local frozen_fixture = frozen[fixture_id]
      local expected_trace = expected[fixture_id]
      local actual_trace = actual[fixture_id]
      t.is_true(expected_trace ~= nil, fixture_id .. ": expected trace")
      t.is_true(actual_trace ~= nil, fixture_id .. ": actual trace")
      local expected_step = expected_trace.steps[1]
      t.eq(expected_step.cas_status, frozen_fixture.cas_status)
      t.eq(expected_step.reason_code, frozen_fixture.reason_code)
      t.eq(expected_step.cas_outcome, frozen_fixture.cas_outcome)
      t.eq(
        observation.canonical_json(expected_step.effect_ids),
        observation.canonical_json(frozen_fixture.granted_effect_ids)
      )
      t.eq(
        observation.canonical_json(expected_step.observable_writes),
        observation.canonical_json(frozen_fixture.observable_writes)
      )
      t.eq(
        observation.canonical_json(actual_trace),
        observation.canonical_json(expected_trace),
        fixture_id .. ": actual restart trace equals expected byte-exact"
      )
    end
  end,
}
