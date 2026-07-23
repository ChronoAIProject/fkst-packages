local observation = require("testkit_internal.old_behavior_observation_support")
local owner_projection = require("devloop.restart_owner_pending_projection")
local restart_obligations = require("devloop.restart_obligations")
local restart_trace = require("devloop.restart_trace")
local trace_derivation = require("devloop.restart_trace_derivation")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local conv_reconcile = require("devloop.convergence.reconcile")
local transition_version = require("contract.transition_version")
local h = require("tests.devloop_helpers")

local t = h.t
local NULL = restart_trace.null
local OWNER = "github-devloop"
local ISSUE_EDGE_ID = OWNER .. "/thinking/entry/issue_reconcile_true_stall"
local TIMEOUT_EDGE_ID = OWNER .. "/ready/timeout/actionable_kickoff_timeout"
local ISSUE_CORPUS = "migration/intent_bounded_replay/corpus/issue-reconcile.json"
local TIMEOUT_CORPUS = "migration/intent_bounded_replay/corpus/timeout-reconcile.json"
local V_EQUAL = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local READY_NEWER_VERSION = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"

local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}

local function index_by(values, field)
  local result = {}
  for _, value in ipairs(values) do
    result[value[field]] = value
  end
  return result
end

local function canonical_edges()
  return owner_projection.edges(OWNER, h.core.restart_transition_table(), inventories)
end

local function frozen_fixture(path, fixture_id)
  local corpus = json.decode(file.read(path))
  local fixture = index_by(corpus.fixtures, "fixture_id")[fixture_id]
  t.is_true(fixture ~= nil, fixture_id .. ": frozen fixture")
  return fixture
end

local function r5_cases(edges)
  local source_witnesses = {
    require("core.restart.issue_reconcile_obligations")[1],
    require("core.restart.timeout_obligations")[1],
  }
  local witness_index = {}
  for _, witness in ipairs(source_witnesses) do
    witness_index[witness.edge_id] = witness
  end
  local result = restart_obligations.derive(edges, witness_index)
  t.eq(#result.obligations, 2, "issue owner CAS-admission obligation count")
  return index_by(result.obligations, "edge_id"), witness_index
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

local function actual_trace(args)
  return restart_trace.define({
    schema = "restart-trace.v1",
    owner = OWNER,
    fixture_id = args.fixture_id,
    steps = restart_trace.array({
      {
        edge_id = args.decision.edge_id,
        row_replay_id = NULL,
        kind = args.edge.kind,
        source = {
          state = observation.nullable(args.edge.source.state),
          boundary = observation.nullable(args.edge.source.boundary),
        },
        target = args.edge.target,
        cause_evidence = args.cause_evidence,
        cas_policy_id = args.decision.cas_policy_id,
        cas_status = args.decision.status,
        reason_code = args.decision.reason_code,
        cas_outcome = args.decision.cas_outcome,
        pending_status = args.edge.pending_order.participates and "included" or "excluded",
        generation_epoch = args.generation_epoch,
        grant_fingerprint = args.grant_fingerprint,
        effect_entitlement_id = args.decision.effect_entitlement_id or NULL,
        effect_ids = restart_trace.array(args.decision.granted_effect_ids),
        queue = args.queue,
        payload_obligations = payload_obligations(args.decision.granted_effect_ids),
        observable_writes = args.observable_writes,
        terminal_why = args.terminal_why,
      },
    }),
  })
end

local function emit_issue_reconcile(snapshot, decision, reconcile, fixture_id)
  local writes = restart_trace.array()
  local grant = restart_effects.mint_grant(
    snapshot,
    decision,
    "comment:issue:reconcile-blocked"
  )
  t.is_true(grant ~= nil, fixture_id .. ": real grant minted")
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
    t.is_true(emitted ~= nil, fixture_id .. ": real facade effect " .. tostring(rejection))
    table.insert(writes, observation.admission_trace_write(
      ordinal,
      effect_id,
      emitted,
      fixture_id .. ": actual generator trace"
    ))
  end
  return writes, restart_trace.grant_fingerprint({
    snapshot_fingerprint = snapshot.snapshot_fingerprint,
    edge_id = decision.edge_id,
    effect_entitlement_id = decision.effect_entitlement_id,
  })
end

local function issue_reconcile_case(edge, obligation, source_witness)
  local fixture = frozen_fixture(ISSUE_CORPUS, source_witness.input_fixture_id)
  local reconcile = h.reconcile()
  reconcile.base_version = V_EQUAL
  reconcile.dedup_key = "reconcile:" .. V_EQUAL .. "/loop/" .. tostring(reconcile.round)
  local incoming_version = conv_reconcile.reconcile_terminal_state_version(
    V_EQUAL,
    reconcile.round
  )
  local witness = {
    owner = OWNER,
    edge_id = edge.id,
    input_fixture_id = fixture.fixture_id,
    witness_id = source_witness.witness_id,
    expected_decision = {
      cas_status = fixture.cas_status,
      reason_code = fixture.reason_code,
      cas_outcome = fixture.cas_outcome,
    },
    expected_effect_ids = restart_trace.array(fixture.granted_effect_ids),
    expected_payload_obligations = restart_trace.array(
      source_witness.expected_payload_obligations
    ),
    trace = {
      snapshot_fingerprint = "r9-issue-reconcile:" .. fixture.fixture_id,
      generation_epoch = {
        current_version = V_EQUAL,
        incoming_version = incoming_version,
        generation = V_EQUAL,
        lock_epoch = "r9-issue-reconcile:lock",
      },
      effect_entitlement_id = fixture.effect_entitlement_id,
      queue = edge.source.boundary,
      observable_writes = restart_trace.array(fixture.observable_writes),
      terminal_why = { terminal_cause = reconcile.terminal_cause },
    },
  }

  local function execute()
    local snapshot = restart_effects.seal_snapshot({
      owner = OWNER,
      entity = { kind = "issue", repo = "owner/repo", number = 42 },
      proposal_id = reconcile.proposal_id,
      current = { state = "thinking", version = V_EQUAL },
      snapshot_fingerprint = witness.trace.snapshot_fingerprint,
      lock_epoch = witness.trace.generation_epoch.lock_epoch,
      generation = witness.trace.generation_epoch.generation,
    })
    local decision = restart_effects.decide_transition(snapshot, {
      semantic_variant = "issue_reconcile_true_stall",
      source_boundary = "devloop_reconcile",
      target = "blocked",
      incoming_version = incoming_version,
    })
    local writes, fingerprint = emit_issue_reconcile(
      snapshot,
      decision,
      reconcile,
      fixture.fixture_id
    )
    return actual_trace({
      edge = edge,
      fixture_id = fixture.fixture_id,
      decision = decision,
      cause_evidence = { source_boundary = edge.source.boundary },
      generation_epoch = {
        current_version = snapshot.current.version,
        incoming_version = decision.incoming_version,
        generation = snapshot.generation,
        lock_epoch = snapshot.lock_epoch,
      },
      grant_fingerprint = fingerprint,
      queue = edge.source.boundary,
      observable_writes = writes,
      terminal_why = { terminal_cause = reconcile.terminal_cause },
    })
  end

  return trace_derivation.derive_cas_admission(edge, obligation, witness), execute
end

local function timeout_case(edge, obligation, source_witness)
  local fixture = frozen_fixture(TIMEOUT_CORPUS, source_witness.input_fixture_id)
  local incoming_version = conv_reconcile.timeout_reconcile_state_version(
    transition_version.timeout_at(READY_NEWER_VERSION, "ready", 3),
    "ready",
    3
  )
  local witness = {
    owner = OWNER,
    edge_id = edge.id,
    input_fixture_id = fixture.fixture_id,
    witness_id = source_witness.witness_id,
    expected_decision = {
      cas_status = fixture.cas_status,
      reason_code = fixture.reason_code,
      cas_outcome = fixture.cas_outcome,
    },
    expected_effect_ids = restart_trace.array(fixture.granted_effect_ids),
    expected_payload_obligations = restart_trace.array(
      source_witness.expected_payload_obligations
    ),
    trace = {
      snapshot_fingerprint = "r9-timeout-reconcile:" .. fixture.fixture_id,
      generation_epoch = {
        current_version = NULL,
        incoming_version = incoming_version,
        generation = "r9-timeout-reconcile:generation",
        lock_epoch = "r9-timeout-reconcile:lock",
      },
      effect_entitlement_id = fixture.effect_entitlement_id,
      queue = "devloop_timeout_reconcile",
      observable_writes = restart_trace.array(fixture.observable_writes),
      terminal_why = NULL,
    },
  }

  local function execute()
    local snapshot = restart_effects.seal_snapshot({
      owner = OWNER,
      entity = { kind = "issue", repo = "owner/repo", number = 42 },
      proposal_id = "github-devloop/issue/owner/repo/42",
      current = { state = nil, version = nil },
      snapshot_fingerprint = witness.trace.snapshot_fingerprint,
      lock_epoch = witness.trace.generation_epoch.lock_epoch,
      generation = witness.trace.generation_epoch.generation,
    })
    local decision = restart_effects.decide_transition(snapshot, {
      semantic_variant = "actionable_kickoff_timeout",
      target = "blocked",
      incoming_version = incoming_version,
    })
    t.eq(decision.status, "pending", fixture.fixture_id .. ": no facade effects admitted")
    return actual_trace({
      edge = edge,
      fixture_id = fixture.fixture_id,
      decision = decision,
      cause_evidence = {
        timeout_evidence_policy_id = edge.timeout_evidence_policy_id,
      },
      generation_epoch = {
        current_version = NULL,
        incoming_version = incoming_version,
        generation = snapshot.generation,
        lock_epoch = snapshot.lock_epoch,
      },
      grant_fingerprint = NULL,
      queue = "devloop_timeout_reconcile",
      observable_writes = restart_trace.array(),
      terminal_why = NULL,
    })
  end

  return trace_derivation.derive_cas_admission(edge, obligation, witness), execute
end

return {
  test_cas_trace_derivation_fails_closed_without_an_r5_mapping = function()
    local edge = index_by(canonical_edges(), "id")[ISSUE_EDGE_ID]
    local ok = pcall(trace_derivation.derive_cas_admission, edge, nil, nil)
    t.eq(ok, false)
  end,

  test_issue_owner_derives_and_executes_cas_admission_restart_traces = function()
    local edges = canonical_edges()
    local edge_by_id = index_by(edges, "id")
    local obligations, source_witnesses = r5_cases(edges)
    local issue_expected, issue_execute = issue_reconcile_case(
      edge_by_id[ISSUE_EDGE_ID],
      obligations[ISSUE_EDGE_ID],
      source_witnesses[ISSUE_EDGE_ID]
    )
    local timeout_expected, timeout_execute = timeout_case(
      edge_by_id[TIMEOUT_EDGE_ID],
      obligations[TIMEOUT_EDGE_ID],
      source_witnesses[TIMEOUT_EDGE_ID]
    )
    local cases = {
      { issue_expected, issue_execute },
      { timeout_expected, timeout_execute },
    }
    t.eq(#cases, 2)
    for _, case in ipairs(cases) do
      local expected, execute = case[1], case[2]
      local actual = execute()
      t.eq(
        observation.canonical_json(actual),
        observation.canonical_json(expected),
        expected.fixture_id .. ": actual equals R5-derived expected byte-exact"
      )
      local encoded = observation.canonical_json(expected)
      t.eq(encoded:find('"grant":', 1, true), nil, "no serialized grant")
      t.eq(encoded:find('"seal', 1, true), nil, "no serialized seal")
    end
  end,
}
