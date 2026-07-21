local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local observation = require("testkit_internal.old_behavior_observation_support")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local testing = require("testkit_internal.testing")
local h = require("tests.devloop_helpers")

local t = h.t
local core = h.core
local canonical_json = observation.canonical_json
local json_array = observation.json_array
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local CORPUS_PATH = "migration/intent_bounded_replay/corpus/issue-reconcile.json"
local APPLY_OBSERVATION_ID =
  "writer:github-devloop:reconcile-thinking-blocked/blocked/apply/apply/blocked"
local V_OLDER = "consensus:github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local TRACE_EDGE_ID = core.restart_package_name
  .. "/thinking/entry/issue_reconcile_true_stall"

local function reconcile_event(base_version)
  local event = h.reconcile()
  event.base_version = base_version or event.base_version
  event.dedup_key = "reconcile:" .. tostring(event.base_version)
    .. "/loop/" .. tostring(event.round)
  return event
end

local function frozen_apply_writes()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if record.observation_id == APPLY_OBSERVATION_ID then
      local writes = json_array()
      for _, write in ipairs(record.old_outcome.observable_writes or {}) do
        table.insert(writes, {
          queue = write.queue,
          payload = observation.copy_value(write.payload),
        })
      end
      return writes
    end
  end
  error("R9 issue-reconcile frozen OLD apply observation is missing", 0)
end

local function run_production(options)
  options = options or {}
  local event = options.event or reconcile_event(options.base_version)
  local comments = {}
  if options.current_state ~= nil then
    table.insert(comments, core.state_marker(
      event.proposal_id,
      options.current_state,
      options.current_version
    ))
  end
  h.mock_bot_env()
  h.mock_issue_reconcile({}, comments)

  local calls = {
    seal = {},
    decide = {},
    mint = {},
    verify = {},
    logs = {},
    raises = 0,
  }
  local original = {
    seal = restart_effects.seal_snapshot,
    decide = restart_effects.decide_transition,
    mint = restart_effects.mint_grant,
    verify = restart_effects.verify_grant,
    cas = devloop_state.versioned_transition_status,
    log_cas = devloop_logging.log_cas_decision,
    log_raise = devloop_logging.log_raise,
  }
  restart_effects.seal_snapshot = function(fields)
    table.insert(calls.seal, observation.copy_value(fields))
    return original.seal(fields)
  end
  restart_effects.decide_transition = function(snapshot, intent)
    local decision = original.decide(snapshot, intent)
    table.insert(calls.decide, {
      intent = observation.copy_value(intent),
      decision = observation.copy_value(decision),
    })
    return decision
  end
  restart_effects.mint_grant = function(snapshot, decision, sink_id)
    table.insert(calls.mint, sink_id)
    if options.reject_mint then return nil end
    return original.mint(snapshot, decision, sink_id)
  end
  restart_effects.verify_grant = function(grant, effect_id, snapshot)
    table.insert(calls.verify, effect_id)
    if options.reject_verify then return false end
    return original.verify(grant, effect_id, snapshot)
  end
  devloop_state.versioned_transition_status = function()
    error("issue-reconcile production used retired direct CAS", 0)
  end
  devloop_logging.log_cas_decision = function(...)
    local fields = { ... }
    table.insert(calls.logs, {
      dept = fields[1],
      from_state = fields[4],
      to_state = fields[5],
      outcome = fields[6],
      reason = fields[7],
    })
    return original.log_cas(...)
  end
  devloop_logging.log_raise = function(...)
    calls.raises = calls.raises + 1
    return original.log_raise(...)
  end

  local department = require("departments.reconcile.main")
  local ok, result = pcall(testing.run_fake, department, {
    queue = "devloop_reconcile",
    payload = event,
  })

  devloop_logging.log_raise = original.log_raise
  devloop_logging.log_cas_decision = original.log_cas
  devloop_state.versioned_transition_status = original.cas
  restart_effects.verify_grant = original.verify
  restart_effects.mint_grant = original.mint
  restart_effects.decide_transition = original.decide
  restart_effects.seal_snapshot = original.seal
  if not ok then
    return nil, calls, event, tostring(result)
  end
  return result, calls, event, nil
end

local function ordered_writes(raises)
  local writes = json_array()
  for _, raised in ipairs(raises or {}) do
    table.insert(writes, {
      queue = raised.queue,
      payload = observation.copy_value(raised.payload),
    })
  end
  return writes
end

local function trace_fixture(fixture, decision, writes)
  return observation.admission_trace_fixture(
    fixture,
    TRACE_EDGE_ID,
    decision.status,
    decision.reason_code,
    decision.cas_outcome,
    decision.effect_entitlement_id,
    decision.granted_effect_ids,
    writes
  )
end

local TRACE_FIXTURES = {
  {
    fixture_id = "source-equal-apply",
    current_state = "thinking",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
  },
  {
    fixture_id = "source-marker-missing-pending",
    current_state = nil,
    current_version = nil,
    incoming_version = V_NEWER,
  },
  {
    fixture_id = "source-state-advanced-stale",
    current_state = "ready",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
  },
  {
    fixture_id = "target-idempotent",
    current_state = "blocked",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
  },
}

local function normalized_trace_fixture(fixture)
  local event = reconcile_event(fixture.incoming_version)
  local incoming_version = conv_reconcile.reconcile_terminal_state_version(
    fixture.current_version or fixture.incoming_version,
    event.round
  )
  local snapshot = restart_effects.seal_snapshot({
    owner = core.restart_package_name,
    entity = { kind = "issue", repo = "owner/repo", number = 42 },
    proposal_id = event.proposal_id,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
    snapshot_fingerprint = "r9-issue-reconcile:" .. fixture.fixture_id,
    lock_epoch = "r9-issue-reconcile:lock",
    generation = fixture.current_version or "r9-issue-reconcile:missing",
  })
  local decision = restart_effects.decide_transition(snapshot, {
    semantic_variant = "issue_reconcile_true_stall",
    source_boundary = "devloop_reconcile",
    target = "blocked",
    incoming_version = incoming_version,
  })
  local writes = json_array()
  if decision.status == "apply" then
    local grant = restart_effects.mint_grant(
      snapshot,
      decision,
      "comment:issue:reconcile-blocked"
    )
    t.is_true(grant ~= nil, fixture.fixture_id .. ": grant minted")
    local facade = restart_effect_facade.make({
      family = "issue-reconcile",
      verify_grant = restart_effects.verify_grant,
      sink_inventory = require("core.restart.sink_inventory"),
    })
    local args = {
      core = core,
      issue = { repo = "owner/repo", number = "42" },
      reconcile = event,
      action = "drop",
      reason = tostring(event.terminal_cause)
        .. "-after-" .. tostring(event.round) .. "-rounds",
      state_version = incoming_version,
    }
    for ordinal, effect_id in ipairs(decision.granted_effect_ids) do
      local emitted = facade.emit(grant, effect_id, snapshot, args)
      t.is_true(emitted ~= nil, fixture.fixture_id .. ": facade emitted " .. effect_id)
      table.insert(writes, observation.admission_trace_write(
        ordinal,
        effect_id,
        emitted,
        "R9 issue-reconcile trace"
      ))
    end
  end
  return trace_fixture(fixture, decision, writes)
end

return {
  test_issue_reconcile_production_grant_path_is_full_payload_exact = function()
    local result, calls, event = run_production({
      current_state = "thinking",
      current_version = V_EQUAL,
    })
    local incoming_version = conv_reconcile.reconcile_terminal_state_version(
      V_EQUAL,
      event.round
    )
    local lock_key = entity_lib.loop_lock_key(event.proposal_id)

    t.eq(type(result), "table", "production swap result")
    t.eq(calls.raises, 2, "production emits exactly two effects")
    t.eq(#calls.seal, 1, "one sealed snapshot")
    t.eq(#calls.decide, 1, "one owner decision")
    t.eq(#calls.mint, 1, "one minted grant")
    t.eq(#calls.verify, 2, "two consumed entitlements")
    t.eq(calls.seal[1].snapshot_fingerprint,
      table.concat({ "issue-reconcile", event.proposal_id, "thinking", V_EQUAL }, "|"))
    t.eq(calls.seal[1].lock_epoch, lock_key .. "@" .. V_EQUAL)
    t.eq(calls.seal[1].generation, V_EQUAL)
    t.eq(calls.decide[1].intent.semantic_variant, "issue_reconcile_true_stall")
    t.eq(calls.decide[1].intent.source_boundary, "devloop_reconcile")
    t.eq(calls.decide[1].intent.target, "blocked")
    t.eq(calls.decide[1].intent.incoming_version, incoming_version)
    t.eq(calls.decide[1].decision.status, "apply")
    t.eq(calls.mint[1], "comment:issue:reconcile-blocked")
    t.eq(calls.verify[1], "github-proxy.github_issue_comment_request")
    t.eq(calls.verify[2], "github-proxy.github_issue_label_request")
    t.eq(calls.logs[1].outcome, "applied", "legacy apply log is exact")
    t.eq(calls.logs[1].reason, "no-semantic-progress-after-3-rounds")
    t.eq(
      canonical_json(ordered_writes(result.raises)),
      canonical_json(frozen_apply_writes()),
      "R9 canonical ordered full payload is byte-exact versus frozen OLD"
    )
  end,

  test_issue_reconcile_pre_decision_outcomes_and_logs_remain_exact = function()
    local cases = {
      {
        name = "pending",
        current_state = nil,
        current_version = nil,
        outcome = "pending",
        failure = "state-marker-pending",
      },
      {
        name = "idempotent",
        current_state = "blocked",
        current_version = V_EQUAL,
        outcome = "skip-idempotent(already terminal)",
      },
      {
        name = "stale",
        current_state = "ready",
        current_version = V_EQUAL,
        outcome = "skip-stale(state-advanced)",
      },
    }
    for _, case in ipairs(cases) do
      local result, calls, _, failure = run_production(case)
      t.eq(#calls.decide, 0, case.name .. ": guard precedes owner decision")
      t.eq(calls.raises, 0, case.name .. ": no effects")
      t.eq(calls.logs[1].outcome, case.outcome, case.name .. ": exact legacy log")
      if case.failure ~= nil then
        t.eq(result, nil, case.name .. ": fails for retry")
        t.is_true(failure:find(case.failure, 1, true) ~= nil)
      else
        t.eq(type(result), "table", case.name .. ": returns without failure")
      end
    end
  end,

  test_issue_reconcile_grant_failures_emit_nothing = function()
    for _, case in ipairs({
      { reject_mint = true, failure = "restart-effect-grant-mint-failed" },
      { reject_verify = true, failure = "restart-effect-facade-rejected" },
    }) do
      case.current_state = "thinking"
      case.current_version = V_EQUAL
      local result, calls, _, failure = run_production(case)
      t.eq(result, nil)
      t.eq(calls.raises, 0, case.failure .. ": no partial effect")
      t.is_true(failure:find(case.failure, 1, true) ~= nil)
    end
  end,

  test_issue_reconcile_new_trace_equals_committed_r9_corpus = function()
    local corpus = json.decode(file.read(CORPUS_PATH))
    local fixtures = json_array()
    for _, fixture in ipairs(TRACE_FIXTURES) do
      table.insert(fixtures, normalized_trace_fixture(fixture))
    end
    local trace = observation.admission_trace_artifact(
      "restart-issue-reconcile-trace.v1",
      core.restart_package_name,
      "issue-reconcile",
      corpus.artifact_sha256,
      fixtures
    )
    t.eq(canonical_json(trace), canonical_json(corpus),
      "R9 issue-reconcile NEW semantic trace equals committed corpus")
  end,

  test_issue_reconcile_malformed_payload_fails_closed_before_decision = function()
    local event = reconcile_event(42)
    local result, calls = run_production({ event = event })
    t.eq(type(result), "table")
    t.eq(#calls.decide, 0)
    t.eq(calls.raises, 0)
    t.eq(calls.logs[1].outcome, "skip-foreign(proposal_id)")
  end,
}
