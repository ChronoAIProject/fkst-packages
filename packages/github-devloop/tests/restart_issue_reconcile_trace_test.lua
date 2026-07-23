local observation = require("testkit_internal.old_behavior_observation_support")
local restart_trace = require("devloop.restart_trace")
local expected_traces = require("core.restart.issue_reconcile_traces")
local obligations = require("core.restart.issue_reconcile_obligations")
local restart_authority = require("core.restart_authority")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local conv_reconcile = require("devloop.convergence.reconcile")
local h = require("tests.devloop_helpers")

local t = h.t
local NULL = restart_trace.null
local CORPUS_PATH = "migration/intent_bounded_replay/corpus/issue-reconcile.json"
local EDGE_ID = "github-devloop/thinking/entry/issue_reconcile_true_stall"
local V_EQUAL = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"

local function index_by(values, field)
  local result = {}
  for _, value in ipairs(values) do
    result[value[field]] = value
  end
  return result
end

local function issue_reconcile_edge()
  for _, edge in ipairs(restart_authority.edges()) do
    if edge.id == EDGE_ID then
      return edge
    end
  end
  error("restart issue reconcile trace: entry edge is missing", 0)
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

local inputs = {
  ["source-equal-apply"] = {
    current = { state = "thinking", version = V_EQUAL },
    base_version = V_EQUAL,
  },
  ["source-marker-missing-pending"] = {
    current = { state = nil, version = nil },
    base_version = V_NEWER,
  },
  ["source-state-advanced-stale"] = {
    current = { state = "ready", version = V_EQUAL },
    base_version = V_EQUAL,
  },
  ["target-idempotent"] = {
    current = { state = "blocked", version = V_EQUAL },
    base_version = V_EQUAL,
  },
}

local function reconcile_fixture(base_version)
  local reconcile = h.reconcile()
  reconcile.base_version = base_version
  reconcile.dedup_key = "reconcile:" .. tostring(base_version)
    .. "/loop/" .. tostring(reconcile.round)
  return reconcile
end

local function actual_writes(fixture_id, snapshot, decision, reconcile)
  local writes = restart_trace.array()
  if decision.status ~= "apply" then
    return writes, NULL, NULL
  end

  local grant = restart_effects.mint_grant(
    snapshot,
    decision,
    "comment:issue:reconcile-blocked"
  )
  t.is_true(grant ~= nil, fixture_id .. ": actual grant minted")
  local facade = restart_effect_facade.make({
    family = "issue-reconcile",
    verify_grant = restart_effects.verify_grant,
    sink_inventory = require("core.restart.sink_inventory"),
  })
  local args = {
    core = h.core,
    issue = { repo = "owner/repo", number = "42" },
    reconcile = reconcile,
    action = "drop",
    reason = tostring(reconcile.terminal_cause)
      .. "-after-" .. tostring(reconcile.round) .. "-rounds",
    state_version = decision.incoming_version,
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
    terminal_cause = reconcile.terminal_cause,
  }
end

local function actual_traces(corpus)
  local edge = issue_reconcile_edge()
  local traces = restart_trace.array()
  for _, fixture in ipairs(corpus.fixtures) do
    local input = inputs[fixture.fixture_id]
    t.is_true(input ~= nil, fixture.fixture_id .. ": actual input fixture")
    local reconcile = reconcile_fixture(input.base_version)
    local incoming_version = conv_reconcile.reconcile_terminal_state_version(
      input.current.version or input.base_version,
      reconcile.round
    )
    local snapshot = restart_effects.seal_snapshot({
      owner = corpus.owner,
      entity = { kind = "issue", repo = "owner/repo", number = 42 },
      proposal_id = reconcile.proposal_id,
      current = input.current,
      snapshot_fingerprint = "r9-issue-reconcile:" .. fixture.fixture_id,
      lock_epoch = "r9-issue-reconcile:lock",
      generation = input.current.version or "r9-issue-reconcile:missing",
    })
    local decision = restart_effects.decide_transition(snapshot, {
      semantic_variant = "issue_reconcile_true_stall",
      source_boundary = "devloop_reconcile",
      target = "blocked",
      incoming_version = incoming_version,
    })
    local writes, grant_fingerprint, terminal_why = actual_writes(
      fixture.fixture_id,
      snapshot,
      decision,
      reconcile
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
          source = {
            state = edge.source.state,
            boundary = edge.source.boundary,
          },
          target = edge.target,
          cause_evidence = {
            source_boundary = edge.source.boundary,
          },
          cas_policy_id = decision.cas_policy_id,
          cas_status = decision.status,
          reason_code = decision.reason_code,
          cas_outcome = decision.cas_outcome,
          pending_status = edge.pending_order.participates and "included" or "excluded",
          generation_epoch = {
            current_version = observation.nullable(input.current.version),
            incoming_version = incoming_version,
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
    }))
  end
  return traces
end

return {
  test_issue_reconcile_restart_traces_match_authority_facade_and_frozen_corpus = function()
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
      t.eq(expected_step.effect_entitlement_id,
        observation.nullable(frozen_fixture.effect_entitlement_id))
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
