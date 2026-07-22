-- Non-circularity contract: production truth comes from the real
-- consensus_result department's CAS probe and the first result-marker guard.
-- Effect repair and legacy CAS logs are separate post-admission observations.
-- This test never computes the expected admission with a transition helper.

local catalog = require("devloop.restart_cas_catalog")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local devloop_logging = require("devloop.logging")
local m_builders = require("devloop.markers.builders")
local devloop_state = require("devloop.state")
local h = require("tests.devloop_helpers")
local restart_authority = require("core.restart_authority")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)

local canonical_json = observation_support.canonical_json
local json_array = observation_support.json_array
local THINKING_CORPUS_PATH = "migration/intent_bounded_replay/corpus/thinking.json"
local THINKING_NEW_TRACE_PATH = ".fkst/run/r9-thinking-new-trace.json"

local OWNER = core.restart_package_name
local POLICY_ID = "cas.legacy_consensus_result_v1"
local V_OLDER = "consensus:github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local V_ORDERING_EQUAL_CURRENT = V_EQUAL .. "/loop/01"
local V_ORDERING_EQUAL_INCOMING = V_EQUAL .. "/loop/1"

local TARGET_SHADOW = {
  ready = {
    semantic_variant = "consensus-reached",
    cas_variant = "thinking_to_ready",
  },
  dependency_wait = {
    semantic_variant = "consensus-reached-dependency-held",
    cas_variant = "thinking_to_dependency_wait",
  },
  declined = {
    semantic_variant = "premise-refuted",
    cas_variant = "thinking_to_declined",
  },
}

local function shadow_for_target(target_state)
  local shadow = TARGET_SHADOW[target_state]
  if shadow == nil then
    error("consensus-result parity has no shadow variant for target: " .. tostring(target_state))
  end
  return shadow
end

local function observe_department(run)
  local probes = {}
  local decisions = {}
  local result_marker_checks = {}
  local original_versioned = devloop_state.versioned_transition_status
  local original_log_cas = devloop_logging.log_cas_decision
  local original_has_result_marker = devloop_state.has_result_marker

  devloop_state.versioned_transition_status = function(current, from_states, to_state, incoming_version)
    local outcome = original_versioned(current, from_states, to_state, incoming_version)
    table.insert(probes, {
      current = current,
      from_states = from_states,
      to_state = to_state,
      incoming_version = incoming_version,
      outcome = outcome,
    })
    return outcome
  end
  devloop_logging.log_cas_decision = function(dept, proposal_id, current, from_state, to_state, outcome, reason)
    table.insert(decisions, {
      dept = dept,
      proposal_id = proposal_id,
      current = current,
      from_state = from_state,
      to_state = to_state,
      outcome = outcome,
      reason = reason,
    })
    return original_log_cas(dept, proposal_id, current, from_state, to_state, outcome, reason)
  end
  devloop_state.has_result_marker = function(comments, proposal_id, decision, dedup_key, decision_reason)
    table.insert(result_marker_checks, {
      comments = comments,
      proposal_id = proposal_id,
      decision = decision,
      dedup_key = dedup_key,
      decision_reason = decision_reason,
    })
    return original_has_result_marker(comments, proposal_id, decision, dedup_key, decision_reason)
  end

  local ok, result = pcall(run)
  devloop_state.has_result_marker = original_has_result_marker
  devloop_logging.log_cas_decision = original_log_cas
  devloop_state.versioned_transition_status = original_versioned
  if not ok then
    error(result, 0)
  end
  return result, probes, decisions, result_marker_checks
end

-- Admission-only: the catalog's consensus_result policy is a plain versioned base (the
-- effect-completeness repair is extracted to a post-admission disposition), so the catalog
-- evidence carries ONLY the version-concurrency inputs the probe saw (current + incoming
-- version). It does NOT carry effects_complete — effect completeness is observed separately
-- as the post_admission_disposition axis, never fed into the admission decision.
local function evidence_from_source(source)
  return {
    current = devloop_state.current_state(source.comments, source.event.proposal_id),
    variant = shadow_for_target(source.target_state).cas_variant,
    incoming_version = source.event.effect_version or source.event.dedup_key,
  }
end

local function observe_shadow(run)
  local evidence = nil
  local original_resolve = catalog.resolve
  catalog.resolve = function(policy_id, candidate, candidate_projection)
    evidence = candidate
    return original_resolve(policy_id, candidate, candidate_projection)
  end
  local ok, result = pcall(run)
  catalog.resolve = original_resolve
  if not ok then
    error(result, 0)
  end
  return result, evidence
end

local function labels_for_state(state)
  local labels = { "fkst-dev:enabled" }
  if state == "thinking" then
    table.insert(labels, "fkst-dev:thinking")
  elseif state == "ready" or state == "dependency_wait" then
    table.insert(labels, "fkst-dev:ready")
  elseif state == "blocked" then
    table.insert(labels, "fkst-dev:blocked")
  elseif state ~= nil and state ~= "unmanaged" then
    table.insert(labels, "fkst-dev:" .. state)
  end
  if state == "dependency_wait" then
    table.insert(labels, "fkst-dev:blocked-on-dependency")
  end
  return labels
end

local function source_for_fixture(fixture)
  local event = h.reached({
    effect_version = fixture.incoming_version,
    decision = fixture.decision,
    decision_reason = fixture.decision_reason,
  })
  local comments = {}
  if fixture.current_state ~= nil then
    table.insert(comments, core.state_marker(event.proposal_id, fixture.current_state, fixture.current_version))
  end
  if fixture.result_marker_visible then
    table.insert(comments, m_builders.result_marker(
      event.proposal_id,
      event.decision,
      event.dedup_key,
      event.decision_reason
    ))
  end
  return {
    event = event,
    comments = comments,
    labels = fixture.labels or labels_for_state(fixture.current_state),
    target_state = event.decision == "reject"
      and "declined"
      or fixture.dependency_gate == "unresolvable" and "dependency_wait"
      or "ready",
  }
end

local function mock_dependency_gate(fixture)
  if fixture.dependency_gate == "unresolvable" then
    t.mock_command(core.gh_blocked_by_cmd("owner/repo", 42), {
      stdout = "{",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function emitted_state(result)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request" then
      local state = tostring(raised.payload and raised.payload.body or ""):match('state="([^"]+)"')
      if state ~= nil then
        return state
      end
    end
  end
  return nil
end

-- Production's result-effect repair (raise_result_effects) has TWO independent guards: a
-- COMMENT re-raise when the result marker is absent, and a LABEL re-raise when the ready
-- label hint is missing. Effect-completeness is (marker present AND label present), so a
-- present-marker/missing-label drift is still incomplete and repairs the LABEL only (no
-- comment). Disposition must therefore be derived from ALL observed raises, not only the
-- comment body, or a label-only repair is mis-classified as effect-idempotent.
local function label_repaired(result)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "github-proxy.github_issue_label_request" then
      return true
    end
  end
  return false
end

local function observed_admission(probe, decisions, boundary_reached)
  if probe.outcome == "pending" then
    return { status = "pending", reason_code = "source-marker-not-visible" }
  end
  if probe.outcome == "idempotent" then
    return { status = "idempotent", reason_code = "already-at-target" }
  end
  if probe.outcome == "stale" then
    for _, decision in ipairs(decisions) do
      if tostring(decision.outcome or ""):find("incoming version < current marker version", 1, true) ~= nil then
        return { status = "stale", reason_code = "incoming-version-older" }
      end
    end
    return { status = "stale", reason_code = "advanced-or-diverged" }
  end
  if probe.outcome ~= "apply" then
    error("consensus-result admission probe returned an unknown outcome: " .. tostring(probe.outcome))
  end
  if boundary_reached then
    return { status = "apply", reason_code = "apply" }
  end
  error("consensus-result admission apply did not reach the result-marker boundary")
end

local function legacy_log_outcome(decisions)
  local outcomes = {}
  for _, decision in ipairs(decisions) do
    table.insert(outcomes, tostring(decision.outcome or ""))
  end
  return table.concat(outcomes, " | ")
end

local function post_admission_disposition(result, probe, boundary_reached)
  if not boundary_reached then
    return "not-admitted"
  end
  local state = emitted_state(result)
  if probe.outcome == "idempotent" then
    if state ~= nil then
      return "effect-repair(" .. state .. ")"
    end
    if label_repaired(result) then
      return "effect-repair(label)"
    end
    return "effect-idempotent"
  end
  if state ~= nil then
    return "effect-emitted(" .. state .. ")"
  end
  return "effect-partial"
end

local function run_real_department(source, expected_exit_code)
  h.mock_issue_result(source.labels, source.comments)
  local runner = expected_exit_code == 1 and h.run_result_expecting_failure or h.run_result
  return runner(source.event, h.opts("consensus-result-cas-parity"))
end

local function assert_catalog_matches_observed_admission(fixture)
  local source = source_for_fixture(fixture)
  mock_dependency_gate(fixture)
  local result, probes, decisions, result_marker_checks = observe_department(function()
    return run_real_department(source, fixture.expected_exit_code or 0)
  end)

  if fixture.first_result_gate then
    t.eq(#probes, 0, fixture.name .. ": first-result gate precedes CAS")
    t.eq(#result.raises, 0, fixture.name .. ": admitted result is a no-op")
    t.eq(legacy_log_outcome(decisions), "skip-idempotent(first-result)", fixture.name .. ": first-result outcome")
    return
  end

  t.eq(#probes, 1, fixture.name .. ": real department CAS probe count")
  local probe = probes[1]
  t.eq(probe.current.state, fixture.current_state, fixture.name .. ": probe current state")
  t.eq(probe.current.version, fixture.current_version, fixture.name .. ": probe current version")
  t.eq(probe.from_states[1], "thinking", fixture.name .. ": probe source state")
  t.eq(#probe.from_states, 1, fixture.name .. ": probe source state count")
  t.eq(probe.to_state, source.target_state, fixture.name .. ": probe target state")
  t.eq(probe.incoming_version, fixture.incoming_version, fixture.name .. ": probe incoming version")
  t.eq(probe.outcome, fixture.probe_outcome, fixture.name .. ": literal probe outcome")

  t.is_true(#decisions > 0, fixture.name .. ": structured CAS decision captured")
  for _, decision in ipairs(decisions) do
    t.eq(decision.dept, "consensus_result", fixture.name .. ": CAS decision department")
    t.eq(decision.from_state, "thinking", fixture.name .. ": logged source state")
    t.eq(decision.to_state, source.target_state, fixture.name .. ": logged target state")
    t.is_true(type(decision.outcome) == "string", fixture.name .. ": legacy log outcome captured")
    t.is_true(type(decision.reason) == "string", fixture.name .. ": legacy log reason captured")
  end

  local boundary_reached = #result_marker_checks > 0
  t.eq(#result_marker_checks, fixture.boundary_call_count, fixture.name .. ": result-marker admission boundary calls")
  for _, marker_check in ipairs(result_marker_checks) do
    t.eq(marker_check.proposal_id, source.event.proposal_id, fixture.name .. ": boundary proposal")
    t.eq(marker_check.decision, source.event.decision, fixture.name .. ": boundary decision")
    t.eq(marker_check.dedup_key, source.event.dedup_key, fixture.name .. ": boundary dedup")
    t.eq(marker_check.decision_reason, source.event.decision_reason, fixture.name .. ": boundary decision reason")
  end

  local observed = observed_admission(probe, decisions, boundary_reached)
  t.eq(observed.status, fixture.admission_status, fixture.name .. ": observed admission status")
  t.eq(observed.reason_code, fixture.admission_reason_code, fixture.name .. ": observed admission reason")
  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.name .. ": department exit code")
  if fixture.expected_raise_count ~= nil then
    t.eq(#result.raises, fixture.expected_raise_count, fixture.name .. ": production raise count")
  end

  local disposition = post_admission_disposition(result, probe, boundary_reached)
  t.eq(disposition, fixture.post_admission_disposition, fixture.name .. ": post-admission disposition")
  t.eq(legacy_log_outcome(decisions), fixture.legacy_log_outcome, fixture.name .. ": legacy log outcome axis")
  t.eq(emitted_state(result), fixture.effect_state, fixture.name .. ": captured effect state")

  local actual = catalog.resolve(POLICY_ID, evidence_from_source(source), projection)
  t.eq(actual.status, observed.status, fixture.name .. ": admission status parity")
  t.eq(actual.reason_code, observed.reason_code, fixture.name .. ": admission reason parity")
  return {
    result = result,
    source = source,
    probe = probe,
    decision = decisions[1],
    observed = observed,
    actual = actual,
  }
end

local function assert_bidirectional(actual, expected, field, context)
  t.eq(actual[field], expected[field], context .. ": shadow-to-production " .. field)
  t.eq(expected[field], actual[field], context .. ": production-to-shadow " .. field)
end

local function assert_consensus_shadow_case(fixture)
  local production = assert_catalog_matches_observed_admission(fixture)
  local target = production.source.target_state
  local target_shadow = shadow_for_target(target)
  local semantic_variant = target_shadow.semantic_variant
  local cas_variant = target_shadow.cas_variant
  local edge_id = OWNER .. "/thinking/autonomous/" .. semantic_variant
  local sealed_snapshot = restart_authority.seal_snapshot({
    owner = OWNER,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
  })
  local intent = {
    semantic_variant = semantic_variant,
    target = target,
    incoming_version = fixture.incoming_version,
    overlay_version = fixture.incoming_version,
  }

  local shadow, evidence = observe_shadow(function()
    return restart_authority.decide_transition(sealed_snapshot, intent)
  end)
  local observed = {
    status = production.observed.status,
    reason_code = production.observed.reason_code,
    cas_outcome = devloop_state.cas_outcome(
      production.probe.current,
      production.probe.outcome,
      fixture.incoming_version
    ),
  }

  assert_bidirectional(shadow, observed, "status", fixture.name)
  assert_bidirectional(shadow, observed, "reason_code", fixture.name)
  assert_bidirectional(shadow, observed, "cas_outcome", fixture.name)
  t.eq(shadow.edge_id, edge_id, fixture.name .. ": selected edge")
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
  t.eq(evidence.current.state, fixture.current_state, fixture.name .. ": evidence current state")
  t.eq(evidence.current.version, fixture.current_version, fixture.name .. ": evidence raw current version")
  t.eq(evidence.variant, cas_variant, fixture.name .. ": evidence variant")
  t.eq(evidence.incoming_version, fixture.incoming_version, fixture.name .. ": evidence incoming version")
  t.eq(evidence.target_version, nil, fixture.name .. ": evidence target version")
  t.eq(evidence.overlay_version, fixture.incoming_version, fixture.name .. ": evidence overlay version")
end

local function assert_rejected_before_cas()
  local source = source_for_fixture({
    current_state = "thinking",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
  })
  source.event.effect_version = 42
  h.mock_issue_result(source.labels, source.comments)
  local result, probes, decisions, result_marker_checks = observe_department(function()
    return h.run_result_expecting_failure(source.event, h.opts("consensus-result-cas-parity-malformed"))
  end)

  -- Owned malformed results must fail loud; benign skip would recreate the #2111 swallow class.
  t.eq(result.exit_code, 1, "consensus-result-malformed: department exit code")
  t.is_true(tostring(result.failure.error):find("consensus-result-invalid", 1, true) ~= nil, "consensus-result-malformed: fail-loud error")
  t.eq(#probes, 0, "consensus-result-malformed: production rejects before CAS")
  t.eq(#result_marker_checks, 0, "consensus-result-malformed: admission boundary not reached")
  t.eq(#decisions, 0, "consensus-result-malformed: failure precedes legacy rejection logging")

  local evidence = evidence_from_source(source)
  t.eq(evidence.incoming_version, 42, "consensus-result-malformed: catalog sees the same rejected value")
  local resolved = catalog.resolve(POLICY_ID, evidence, projection)
  t.eq(resolved.status, "illegal", "consensus-result-malformed: catalog status")
  t.eq(resolved.reason_code, "invalid-evidence", "consensus-result-malformed: catalog reason")
  t.eq(resolved.cas_outcome, "illegal(invalid-evidence)", "consensus-result-malformed: catalog fails closed")
end

local TRACE_EDGE_ID = OWNER .. "/thinking/autonomous/consensus-reached"
local TRACE_FIXTURES = {
  {
    fixture_id = "newer-source-marker-missing-pending",
    name = "r9-thinking-newer-source-marker-missing",
    current_state = nil,
    current_version = nil,
    incoming_version = V_NEWER,
    probe_outcome = "pending",
    admission_status = "pending",
    admission_reason_code = "source-marker-not-visible",
    boundary_call_count = 0,
    post_admission_disposition = "not-admitted",
    legacy_log_outcome = "retry-pending(from-state marker not yet visible)",
    effect_state = nil,
    expected_exit_code = 1,
  },
  {
    fixture_id = "source-equal-apply",
    name = "r9-thinking-source-equal-apply",
    current_state = "thinking",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    probe_outcome = "apply",
    admission_status = "apply",
    admission_reason_code = "apply",
    boundary_call_count = 2,
    post_admission_disposition = "effect-emitted(ready)",
    legacy_log_outcome = "applied | applied",
    effect_state = "ready",
  },
  {
    fixture_id = "source-older-stale",
    name = "r9-thinking-source-older-stale",
    current_state = "thinking",
    current_version = V_EQUAL,
    incoming_version = V_OLDER,
    probe_outcome = "stale",
    admission_status = "stale",
    admission_reason_code = "incoming-version-older",
    boundary_call_count = 0,
    post_admission_disposition = "not-admitted",
    legacy_log_outcome = "skip-stale(incoming version < current marker version)",
    effect_state = nil,
  },
  {
    fixture_id = "target-incomplete-idempotent",
    name = "r9-thinking-target-incomplete-idempotent",
    current_state = "ready",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    probe_outcome = "idempotent",
    admission_status = "idempotent",
    admission_reason_code = "already-at-target",
    boundary_call_count = 2,
    post_admission_disposition = "effect-repair(ready)",
    legacy_log_outcome = "applied(result effects incomplete)",
    effect_state = "ready",
    expected_raise_count = 1,
  },
}

local trace_write = observation_support.admission_trace_write
local trace_writes = observation_support.admission_trace_writes

local function trace_fixture(
  fixture,
  status,
  reason_code,
  cas_outcome,
  entitlement_id,
  granted_effect_ids,
  writes
)
  return observation_support.admission_trace_fixture(
    fixture,
    TRACE_EDGE_ID,
    status,
    reason_code,
    cas_outcome,
    entitlement_id,
    granted_effect_ids,
    writes
  )
end

local function trace_artifact(corpus_hash, fixtures)
  return observation_support.admission_trace_artifact(
    "restart-thinking-trace.v1",
    OWNER,
    "thinking",
    corpus_hash,
    fixtures
  )
end

local function new_trace_fixture(fixture, production)
  local snapshot = restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "issue", repo = "owner/repo", number = 42 },
    proposal_id = production.source.event.proposal_id,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
    snapshot_fingerprint = "r9-thinking:" .. fixture.fixture_id,
    lock_epoch = "r9-thinking:lock",
    generation = "r9-thinking:generation",
  })
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "consensus-reached",
    incoming_version = fixture.incoming_version,
  })
  local writes = json_array()
  -- The normalized trace records admission application writes only. Idempotent effect repair
  -- is a separately observed post-admission disposition, even though admission grants the full
  -- idempotent entitlement.
  if decided.status == "apply" then
    local grant = restart_effects.mint_grant(snapshot, decided, "comment:issue:thinking-state")
    t.is_true(grant ~= nil, fixture.fixture_id .. ": NEW grant minted")
    local facade = restart_effect_facade.make({
      family = "thinking",
      verify_grant = restart_effects.verify_grant,
      sink_inventory = require("core.restart.sink_inventory"),
    })
    local args = {
      core = core,
      issue = {
        repo = "owner/repo",
        number = 42,
        source_ref = production.source.event.source_ref,
      },
      proposal = production.source.event,
    }
    for ordinal, effect_id in ipairs(decided.granted_effect_ids) do
      local emitted = facade.emit(grant, effect_id, snapshot, args)
      t.is_true(emitted ~= nil, fixture.fixture_id .. ": NEW facade emitted " .. effect_id)
      table.insert(writes, trace_write(ordinal, effect_id, emitted))
    end
  end
  local normalized = trace_fixture(
    fixture,
    decided.status,
    decided.reason_code,
    decided.cas_outcome,
    decided.effect_entitlement_id,
    decided.granted_effect_ids,
    writes
  )
  return normalized, decided
end

local function assert_thinking_trace_equality()
  local corpus = json.decode(file.read(THINKING_CORPUS_PATH))
  local old_fixtures = json_array()
  local new_fixtures = json_array()
  for _, fixture in ipairs(TRACE_FIXTURES) do
    local production = assert_catalog_matches_observed_admission(fixture)
    local new_fixture, normalized_admission = new_trace_fixture(fixture, production)
    local old_writes = production.observed.status == "apply"
      and trace_writes(production.result.raises)
      or json_array()
    table.insert(old_fixtures, trace_fixture(
      fixture,
      production.observed.status,
      production.observed.reason_code,
      devloop_state.cas_outcome(production.probe.current, production.probe.outcome, fixture.incoming_version),
      normalized_admission.effect_entitlement_id,
      normalized_admission.granted_effect_ids,
      old_writes
    ))
    table.insert(new_fixtures, new_fixture)
  end

  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  local new_trace = trace_artifact(corpus.artifact_sha256, new_fixtures)
  t.eq(canonical_json(old_trace), canonical_json(new_trace), "R9 thinking OLD and NEW semantic trace")
  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 thinking trace could not create its artifact directory", 0)
  end
  file.write(THINKING_NEW_TRACE_PATH, canonical_json(new_trace) .. "\n")
  t.eq(canonical_json(old_trace), canonical_json(corpus), "R9 thinking OLD observation corpus")
  t.eq(canonical_json(new_trace), canonical_json(corpus), "R9 thinking NEW semantic trace")
end

return {
  test_consensus_result_source_equal_applies_to_ready = function()
    assert_consensus_shadow_case({
      name = "consensus-result-source-equal-ready",
      current_state = "thinking",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      probe_outcome = "apply",
      admission_status = "apply",
      admission_reason_code = "apply",
      boundary_call_count = 2,
      post_admission_disposition = "effect-emitted(ready)",
      legacy_log_outcome = "applied | applied",
      effect_state = "ready",
    })
  end,

  test_consensus_result_dependency_hold_source_equal_applies = function()
    assert_consensus_shadow_case({
      name = "consensus-result-source-equal-dependency-wait",
      current_state = "thinking",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      dependency_gate = "unresolvable",
      probe_outcome = "apply",
      admission_status = "apply",
      admission_reason_code = "apply",
      boundary_call_count = 2,
      post_admission_disposition = "effect-emitted(dependency_wait)",
      legacy_log_outcome = "applied | hold-dependency",
      effect_state = "dependency_wait",
    })
  end,

  test_consensus_result_declined_source_equal_applies = function()
    assert_consensus_shadow_case({
      name = "consensus-result-declined-source-equal",
      current_state = "thinking",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      decision = "reject",
      decision_reason = "premise-refuted",
      probe_outcome = "apply",
      admission_status = "apply",
      admission_reason_code = "apply",
      boundary_call_count = 2,
      post_admission_disposition = "effect-emitted(declined)",
      legacy_log_outcome = "applied | applied",
      effect_state = "declined",
    })
  end,

  test_consensus_result_declined_target_incomplete_repairs_after_idempotent_admission = function()
    assert_consensus_shadow_case({
      name = "consensus-result-declined-target-incomplete",
      current_state = "declined",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      decision = "reject",
      decision_reason = "premise-refuted",
      probe_outcome = "idempotent",
      admission_status = "idempotent",
      admission_reason_code = "already-at-target",
      boundary_call_count = 2,
      post_admission_disposition = "effect-repair(declined)",
      legacy_log_outcome = "applied(result effects incomplete)",
      effect_state = "declined",
      expected_raise_count = 1,
    })
  end,

  test_consensus_result_declined_source_older_is_stale = function()
    assert_consensus_shadow_case({
      name = "consensus-result-declined-source-older",
      current_state = "thinking",
      current_version = V_EQUAL,
      incoming_version = V_OLDER,
      decision = "reject",
      decision_reason = "premise-refuted",
      probe_outcome = "stale",
      admission_status = "stale",
      admission_reason_code = "incoming-version-older",
      boundary_call_count = 0,
      post_admission_disposition = "not-admitted",
      legacy_log_outcome = "skip-stale(incoming version < current marker version)",
      effect_state = nil,
    })
  end,

  test_consensus_result_declined_managed_successor_is_stale = function()
    assert_consensus_shadow_case({
      name = "consensus-result-declined-managed-successor",
      current_state = "ready",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      decision = "reject",
      decision_reason = "premise-refuted",
      probe_outcome = "stale",
      admission_status = "stale",
      admission_reason_code = "advanced-or-diverged",
      boundary_call_count = 0,
      post_admission_disposition = "not-admitted",
      legacy_log_outcome = "skip-advanced-or-diverged",
      effect_state = nil,
    })
  end,

  test_consensus_result_source_older_is_stale = function()
    assert_consensus_shadow_case({
      name = "consensus-result-source-older",
      current_state = "thinking",
      current_version = V_EQUAL,
      incoming_version = V_OLDER,
      probe_outcome = "stale",
      admission_status = "stale",
      admission_reason_code = "incoming-version-older",
      boundary_call_count = 0,
      post_admission_disposition = "not-admitted",
      legacy_log_outcome = "skip-stale(incoming version < current marker version)",
      effect_state = nil,
    })
  end,

  test_consensus_result_newer_predecessor_is_pending = function()
    assert_consensus_shadow_case({
      name = "consensus-result-newer-source-marker-missing",
      current_state = nil,
      current_version = nil,
      incoming_version = V_NEWER,
      probe_outcome = "pending",
      admission_status = "pending",
      admission_reason_code = "source-marker-not-visible",
      boundary_call_count = 0,
      post_admission_disposition = "not-admitted",
      legacy_log_outcome = "retry-pending(from-state marker not yet visible)",
      effect_state = nil,
      expected_exit_code = 1,
    })
  end,

  test_consensus_result_unrelated_current_is_stale = function()
    assert_consensus_shadow_case({
      name = "consensus-result-unrelated-current",
      current_state = "blocked",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      probe_outcome = "stale",
      admission_status = "stale",
      admission_reason_code = "advanced-or-diverged",
      boundary_call_count = 0,
      post_admission_disposition = "not-admitted",
      legacy_log_outcome = "skip-advanced-or-diverged",
      effect_state = nil,
    })
  end,

  test_consensus_result_target_complete_is_idempotent = function()
    assert_catalog_matches_observed_admission({
      name = "consensus-result-target-complete",
      current_state = "ready",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      result_marker_visible = true,
      first_result_gate = true,
      probe_outcome = "idempotent",
      admission_status = "idempotent",
      admission_reason_code = "already-at-target",
      boundary_call_count = 0,
      post_admission_disposition = "not-admitted",
      legacy_log_outcome = "skip-idempotent(first-result)",
      effect_state = nil,
    })
  end,

  test_consensus_result_target_raw_version_mismatch_is_idempotent_without_repair = function()
    t.is_true(
      V_ORDERING_EQUAL_CURRENT ~= V_ORDERING_EQUAL_INCOMING,
      "consensus-result-target-raw-mismatch: fixture versions must be byte-different"
    )
    assert_consensus_shadow_case({
      name = "consensus-result-target-raw-mismatch",
      current_state = "ready",
      current_version = V_ORDERING_EQUAL_CURRENT,
      incoming_version = V_ORDERING_EQUAL_INCOMING,
      probe_outcome = "idempotent",
      admission_status = "idempotent",
      admission_reason_code = "already-at-target",
      boundary_call_count = 0,
      post_admission_disposition = "not-admitted",
      legacy_log_outcome = "skip-idempotent(already at to_state)",
      effect_state = nil,
    })
  end,

  test_consensus_result_target_incomplete_repairs_after_idempotent_admission = function()
    assert_catalog_matches_observed_admission({
      name = "consensus-result-target-incomplete",
      current_state = "ready",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      probe_outcome = "idempotent",
      admission_status = "idempotent",
      admission_reason_code = "already-at-target",
      boundary_call_count = 2,
      post_admission_disposition = "effect-repair(ready)",
      legacy_log_outcome = "applied(result effects incomplete)",
      effect_state = "ready",
    })
  end,

  -- present-marker/missing-label drift: result marker visible (comment suppressed) but the
  -- ready label hint missing, so completeness is still false and production repairs the
  -- LABEL only. The admission is still idempotent; the disposition is a label-only repair,
  -- which a comment-only observer would mis-classify as effect-idempotent (green-but-wrong).
  test_consensus_result_target_label_only_incomplete_repairs_via_label = function()
    assert_catalog_matches_observed_admission({
      name = "consensus-result-target-label-only-incomplete",
      current_state = "ready",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      result_marker_visible = true,
      first_result_gate = true,
      labels = { "fkst-dev:enabled" },
      probe_outcome = "idempotent",
      admission_status = "idempotent",
      admission_reason_code = "already-at-target",
      boundary_call_count = 0,
      post_admission_disposition = "not-admitted",
      legacy_log_outcome = "skip-idempotent(first-result)",
      effect_state = nil,
    })
  end,

  test_r9_thinking_old_equals_new_normalized_trace = function()
    assert_thinking_trace_equality()
  end,

  test_consensus_result_malformed_evidence_and_payload_fail_closed_before_cas = function()
    assert_rejected_before_cas()
  end,
}
