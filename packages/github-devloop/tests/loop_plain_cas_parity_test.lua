-- Non-circularity contract: production truth comes from the real loop
-- department's transition_status probe and first post-CAS round-marker guard.
-- Catalog admission evidence is copied from observed probe arguments. The
-- outcome version comes from the event dedup key, matching the production log.
-- Effects and legacy CAS logs are separate axes.

local catalog = require("devloop.restart_cas_catalog")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local h = require("tests.devloop_helpers")
local restart_authority = require("core.restart_authority")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)
local loop_department = require("departments.loop.main")

local OWNER = core.restart_package_name
local POLICY_ID = "cas.legacy_loop_plain_v1"
local VARIANT = "thinking_to_blocked"
local V_CURRENT = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_OLDER = "consensus:github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_DIFFERENT = "consensus:github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local TRACE_EDGE_ID = OWNER .. "/thinking/autonomous/consensus-stalled"
local LOOP_PLAIN_CORPUS_PATH = "migration/intent_bounded_replay/corpus/loop-plain.json"
local LOOP_PLAIN_NEW_TRACE_PATH = ".fkst/run/r9-loop-plain-new-trace.json"
local canonical_json = observation_support.canonical_json
local json_array = observation_support.json_array

local state_labels = {
  thinking = "fkst-dev:thinking",
  ready = "fkst-dev:ready",
  blocked = "fkst-dev:blocked",
  ["closed-unmerged"] = "fkst-dev:blocked",
}

local function observe_department(run)
  local probes = {}
  local decisions = {}
  local boundary_calls = {}
  local original_transition = devloop_state.transition_status
  local original_log_cas = devloop_logging.log_cas_decision
  local original_converge_round_facts = conv_rounds.converge_round_facts_for_proposal

  devloop_state.transition_status = function(
    current,
    from_states,
    to_state,
    incoming_version,
    target_version
  )
    local outcome = original_transition(
      current,
      from_states,
      to_state,
      incoming_version,
      target_version
    )
    table.insert(probes, {
      current = current,
      from_states = from_states,
      to_state = to_state,
      incoming_version = incoming_version,
      target_version = target_version,
      outcome = outcome,
    })
    return outcome
  end
  devloop_logging.log_cas_decision = function(
    dept,
    proposal_id,
    current,
    from_state,
    to_state,
    outcome,
    reason
  )
    table.insert(decisions, {
      dept = dept,
      proposal_id = proposal_id,
      current = current,
      from_state = from_state,
      to_state = to_state,
      outcome = outcome,
      reason = reason,
    })
    return original_log_cas(
      dept,
      proposal_id,
      current,
      from_state,
      to_state,
      outcome,
      reason
    )
  end
  conv_rounds.converge_round_facts_for_proposal = function(comments, proposal_id)
    table.insert(boundary_calls, {
      comments = comments,
      proposal_id = proposal_id,
    })
    return original_converge_round_facts(comments, proposal_id)
  end

  local ok, result = pcall(run)
  conv_rounds.converge_round_facts_for_proposal = original_converge_round_facts
  devloop_logging.log_cas_decision = original_log_cas
  devloop_state.transition_status = original_transition
  if not ok then
    error(result, 0)
  end
  return result, probes, decisions, boundary_calls
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

local function evidence_from_probe(probe, outcome_version)
  local definition = catalog.definition(POLICY_ID)
  local variant = definition and definition.variants[VARIANT]
  t.is_true(variant ~= nil, "loop plain probe must select a catalog variant")
  t.eq(definition.production.function_name, "transition_status", "catalog production probe name")
  t.eq(#probe.from_states, #variant.source_states, "catalog source-state count comes from probe")
  for index, source_state in ipairs(probe.from_states) do
    t.eq(variant.source_states[index], source_state, "catalog source state comes from probe")
  end
  t.eq(variant.target_state, probe.to_state, "catalog target state comes from probe")
  return {
    current = probe.current,
    variant = VARIANT,
    incoming_version = outcome_version,
    target_version = probe.target_version,
  }
end

local function observed_admission(probe, boundary_reached, decision)
  if boundary_reached then
    t.eq(probe.outcome, "apply", "loop admission boundary requires an applying CAS probe")
    return { status = "apply", reason_code = "apply" }
  end
  if probe.outcome == "pending" then
    return { status = "pending", reason_code = "source-marker-not-visible" }
  end
  if probe.outcome == "idempotent" then
    return { status = "idempotent", reason_code = "already-at-target" }
  end
  if probe.outcome == "stale" then
    local incoming_older = tostring(decision and decision.outcome or ""):find(
      "incoming version < current marker version",
      1,
      true
    ) ~= nil
    return {
      status = "stale",
      reason_code = incoming_older and "incoming-version-older" or "advanced-or-diverged",
    }
  end
  error("loop plain CAS probe applied without reaching its admission boundary")
end

local function post_admission_disposition(result, decision, boundary_reached)
  if not boundary_reached then
    return "not-admitted"
  end
  if #(result.raises or {}) > 0 then
    return "effects-emitted(" .. tostring(#result.raises) .. ")"
  end
  if tostring(decision and decision.outcome or ""):find("converge round lineage already advanced", 1, true) then
    return "round-idempotent"
  end
  return "admitted-no-effect"
end

local function run_real_department(payload)
  local raises = {}
  local original_raise = raise
  raise = function(queue, raised_payload)
    table.insert(raises, { queue = queue, payload = raised_payload })
  end
  local ok, failure = pcall(loop_department.pipeline, {
    queue = "consensus.consensus_converge",
    payload = payload,
    ts = "2026-06-03T01:02:03Z",
  })
  raise = original_raise
  return {
    exit_code = ok and 0 or 1,
    error = ok and nil or tostring(failure),
    raises = raises,
  }
end

local function fixture_comments(event, fixture)
  local comments = {}
  if fixture.current_state ~= nil then
    table.insert(comments, core.state_marker(
      event.proposal_id,
      fixture.current_state,
      fixture.current_version or V_CURRENT
    ))
  end
  if fixture.round_marker_visible then
    table.insert(comments, conv_rounds.converge_round_marker(
      event.proposal_id,
      fixture.current_version or V_CURRENT,
      convergence_shared.source_ref_digest(event.source_ref),
      0,
      fixture.current_version or V_CURRENT,
      event.narrowed_question,
      event.angle_digests
    ))
  end
  return comments
end

local function assert_bidirectional(actual, expected, field, context)
  t.eq(actual[field], expected[field], context .. ": shadow-to-production " .. field)
  t.eq(expected[field], actual[field], context .. ": production-to-shadow " .. field)
end

local function assert_case(fixture)
  local event = h.unresolved({
    dedup_key = fixture.raw_event_version or V_CURRENT,
    round = 0,
    narrowed_question = "Which fact resolves the remaining gap?",
    angle_digests = {
      { angle = "minimal", verdict = "abstain", digest = "loop-parity" },
    },
  })
  local labels = { "fkst-dev:enabled" }
  if fixture.current_state ~= nil then
    table.insert(labels, state_labels[fixture.current_state] or "fkst-dev:enabled")
  end
  local comments = fixture_comments(event, fixture)
  h.mock_issue_loop(labels, comments)
  if fixture.effect_count ~= nil and fixture.effect_count > 0 then
    h.mock_context_bundle(event)
  end

  local result, probes, decisions, boundary_calls = observe_department(function()
    return run_real_department(event)
  end)

  t.eq(#probes, 1, fixture.name .. ": real department CAS probe count")
  local probe = probes[1]
  t.eq(probe.current.state, fixture.current_state, fixture.name .. ": probe current state")
  t.eq(probe.current.version, fixture.current_version, fixture.name .. ": probe current version")
  t.eq(probe.from_states[1], "thinking", fixture.name .. ": probe source state")
  t.eq(#probe.from_states, 1, fixture.name .. ": probe source state count")
  t.eq(probe.to_state, "blocked", fixture.name .. ": probe target state")
  t.eq(probe.incoming_version, nil, fixture.name .. ": plain probe has no incoming version")
  t.eq(probe.target_version, nil, fixture.name .. ": plain probe has no target version")

  t.eq(#decisions, 1, fixture.name .. ": structured CAS decision count")
  local decision = decisions[1]
  t.eq(decision.dept, "loop", fixture.name .. ": CAS decision department")
  t.eq(decision.from_state, "thinking", fixture.name .. ": logged source state")
  t.eq(decision.to_state, "thinking", fixture.name .. ": logged loop state")
  t.is_true(type(decision.outcome) == "string", fixture.name .. ": legacy log outcome captured")
  t.is_true(type(decision.reason) == "string", fixture.name .. ": legacy log reason captured")

  local boundary_reached = #boundary_calls > 0
  t.eq(#boundary_calls, fixture.boundary_reached and 1 or 0, fixture.name .. ": admission boundary reach")
  if boundary_reached then
    t.eq(boundary_calls[1].proposal_id, event.proposal_id, fixture.name .. ": boundary proposal")
    t.is_true(type(boundary_calls[1].comments) == "table", fixture.name .. ": boundary comments captured")
  end

  local evidence = evidence_from_probe(probe, event.dedup_key)
  t.eq(evidence.current, probe.current, fixture.name .. ": catalog current comes from probe")
  t.eq(evidence.incoming_version, event.dedup_key, fixture.name .. ": catalog incoming version comes from event dedup key")
  t.eq(evidence.target_version, probe.target_version, fixture.name .. ": catalog target version comes from probe")
  local observed = observed_admission(probe, boundary_reached, decision)
  local actual = catalog.resolve(POLICY_ID, evidence, projection)
  t.eq(actual.status, observed.status, fixture.name .. ": admission status parity")
  t.eq(actual.reason_code, observed.reason_code, fixture.name .. ": admission reason parity")
  t.eq(observed.status, fixture.admission_status, fixture.name .. ": observed admission status")
  t.eq(actual.status, fixture.admission_status, fixture.name .. ": catalog admission status")
  if fixture.catalog_cas_outcome ~= nil then
    t.eq(actual.cas_outcome, fixture.catalog_cas_outcome, fixture.name .. ": catalog CAS outcome")
  end

  local sealed_snapshot = restart_authority.seal_snapshot({
    owner = OWNER,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
  })
  local intent = {
    semantic_variant = "consensus-stalled",
    target = "blocked",
    incoming_version = event.dedup_key,
    overlay_version = nil,
  }

  local shadow, shadow_evidence = observe_shadow(function()
    return restart_authority.decide_transition(sealed_snapshot, intent)
  end)
  local shadow_observed = {
    status = observed.status,
    reason_code = observed.reason_code,
    cas_outcome = devloop_state.cas_outcome(probe.current, probe.outcome, event.dedup_key),
  }

  assert_bidirectional(shadow, shadow_observed, "status", fixture.name)
  assert_bidirectional(shadow, shadow_observed, "reason_code", fixture.name)
  assert_bidirectional(shadow, shadow_observed, "cas_outcome", fixture.name)
  t.eq(shadow.edge_id, OWNER .. "/thinking/autonomous/consensus-stalled", fixture.name .. ": selected edge")
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
  t.eq(shadow_evidence.current.state, fixture.current_state, fixture.name .. ": evidence current state")
  t.eq(shadow_evidence.current.version, fixture.current_version, fixture.name .. ": evidence raw current version")
  t.eq(shadow_evidence.variant, VARIANT, fixture.name .. ": evidence variant")
  t.eq(shadow_evidence.incoming_version, event.dedup_key, fixture.name .. ": evidence incoming version")
  t.eq(shadow_evidence.target_version, nil, fixture.name .. ": evidence target version")
  t.eq(shadow_evidence.overlay_version, nil, fixture.name .. ": evidence overlay version")

  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.name .. ": department exit code")
  t.eq(#result.raises, fixture.effect_count or 0, fixture.name .. ": captured effect count")
  t.eq(
    post_admission_disposition(result, decision, boundary_reached),
    fixture.post_admission_disposition or "not-admitted",
    fixture.name .. ": post-admission disposition"
  )
  t.eq(decision.outcome, fixture.legacy_log_outcome, fixture.name .. ": legacy log outcome")
  return {
    event = event,
    result = result,
    probe = probe,
    decision = decision,
    observed = observed,
  }
end

local TRACE_FIXTURES = {
  {
    fixture_id = "newer-source-marker-missing-pending",
    name = "r9-loop-plain-newer-source-marker-missing",
    current_state = nil,
    current_version = nil,
    admission_status = "pending",
    expected_exit_code = 1,
    legacy_log_outcome = "retry-pending(from-state marker not yet visible)",
  },
  {
    fixture_id = "source-equal-apply",
    name = "r9-loop-plain-source-equal-apply",
    current_state = "thinking",
    current_version = V_CURRENT,
    boundary_reached = true,
    admission_status = "apply",
    effect_count = 2,
    post_admission_disposition = "effects-emitted(2)",
    legacy_log_outcome = "applied",
  },
  {
    fixture_id = "source-older-stale",
    name = "r9-loop-plain-source-older-stale",
    current_state = "ready",
    current_version = V_CURRENT,
    raw_event_version = V_OLDER,
    admission_status = "stale",
    catalog_cas_outcome = "skip-stale(incoming version < current marker version)",
    legacy_log_outcome = "skip-stale(incoming version < current marker version)",
  },
  {
    fixture_id = "target-idempotent",
    name = "r9-loop-plain-target-idempotent",
    current_state = "blocked",
    current_version = V_CURRENT,
    admission_status = "idempotent",
    legacy_log_outcome = "skip-idempotent(already at to_state)",
  },
}

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
    "restart-loop-plain-trace.v1",
    OWNER,
    "loop-plain",
    corpus_hash,
    fixtures
  )
end

local function new_trace_fixture(fixture, production)
  local event = production.event
  local snapshot = restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "issue", repo = "owner/repo", number = 42 },
    proposal_id = event.proposal_id,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
    snapshot_fingerprint = "r9-loop-plain:" .. fixture.fixture_id,
    lock_epoch = "r9-loop-plain:lock",
    generation = "r9-loop-plain:generation",
  })
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "consensus-stalled",
    incoming_version = event.dedup_key,
  })
  local writes = json_array()
  if decided.status == "apply" then
    local grant = restart_effects.mint_grant(
      snapshot,
      decided,
      "comment:issue:converge-round"
    )
    t.is_true(grant ~= nil, fixture.fixture_id .. ": NEW grant minted")
    local facade = restart_effect_facade.make({
      family = "loop-plain",
      verify_grant = restart_effects.verify_grant,
      sink_inventory = require("core.restart.sink_inventory"),
    })
    local marker_body = conv_rounds.converge_round_marker(
      event.proposal_id,
      conv_rounds.converge_base_version(event.dedup_key),
      convergence_shared.source_ref_digest(event.source_ref),
      event.round or 0,
      event.dedup_key,
      event.narrowed_question,
      event.angle_digests,
      event.findings_record,
      event.essence_stall == true
    )
    local args = {
      core = core,
      issue = { repo = "owner/repo", number = 42 },
      unresolved = event,
      round = event.round or 0,
      marker_body = marker_body,
    }
    for ordinal, effect_id in ipairs(decided.granted_effect_ids) do
      local emitted = facade.emit(grant, effect_id, snapshot, args)
      t.is_true(emitted ~= nil, fixture.fixture_id .. ": NEW facade emitted " .. effect_id)
      table.insert(
        writes,
        observation_support.admission_trace_write(
          ordinal,
          effect_id,
          emitted,
          "R9 loop-plain trace"
        )
      )
    end
  end
  return trace_fixture(
    fixture,
    decided.status,
    decided.reason_code,
    decided.cas_outcome,
    decided.effect_entitlement_id,
    decided.granted_effect_ids,
    writes
  ), decided
end

local function old_trace_writes(raises, granted_effect_ids)
  local admitted = {}
  for _, effect_id in ipairs(granted_effect_ids or {}) do
    admitted[effect_id] = true
  end
  local scoped = json_array()
  for _, raised in ipairs(raises or {}) do
    if admitted[raised.queue] then
      table.insert(scoped, raised)
    end
  end
  t.eq(#scoped, #(granted_effect_ids or {}), "R9 loop-plain OLD admitted effect count")
  return observation_support.admission_trace_writes(scoped, "R9 loop-plain trace")
end

local function assert_loop_plain_trace_equality()
  local corpus = json.decode(file.read(LOOP_PLAIN_CORPUS_PATH))
  local old_fixtures = json_array()
  local new_fixtures = json_array()
  for _, fixture in ipairs(TRACE_FIXTURES) do
    local production = assert_case(fixture)
    local new_fixture, normalized_admission = new_trace_fixture(fixture, production)
    local writes = production.observed.status == "apply"
      and old_trace_writes(production.result.raises, normalized_admission.granted_effect_ids)
      or json_array()
    table.insert(old_fixtures, trace_fixture(
      fixture,
      production.observed.status,
      production.observed.reason_code,
      production.decision.outcome,
      normalized_admission.effect_entitlement_id,
      normalized_admission.granted_effect_ids,
      writes
    ))
    table.insert(new_fixtures, new_fixture)
  end

  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  local new_trace = trace_artifact(corpus.artifact_sha256, new_fixtures)
  t.eq(canonical_json(old_trace), canonical_json(new_trace), "R9 loop-plain OLD and NEW semantic trace")
  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 loop-plain trace could not create its artifact directory", 0)
  end
  file.write(LOOP_PLAIN_NEW_TRACE_PATH, canonical_json(new_trace) .. "\n")
  t.eq(canonical_json(old_trace), canonical_json(corpus), "R9 loop-plain OLD observation corpus")
  t.eq(canonical_json(new_trace), canonical_json(corpus), "R9 loop-plain NEW semantic trace")
end

local function assert_malformed_pre_cas()
  local payload = h.unresolved({ dedup_key = 42 })
  local result, probes, decisions, boundary_calls = observe_department(function()
    return run_real_department(payload)
  end)
  t.eq(result.exit_code, 0, "loop-malformed: production rejects malformed payload without error")
  t.eq(#probes, 0, "loop-malformed: production rejects before CAS")
  t.eq(#boundary_calls, 0, "loop-malformed: production rejects before admission boundary")
  t.eq(#decisions, 1, "loop-malformed: pre-CAS decision is logged")
  t.eq(decisions[1].outcome, "skip-foreign(proposal_id)", "loop-malformed: legacy log outcome")
end

return {
  test_loop_plain_admission_trace_matches_frozen_old_corpus = function()
    assert_loop_plain_trace_equality()
  end,

  test_loop_plain_source_state_applies_at_round_marker_boundary = function()
    assert_case({
      name = "loop-source-apply",
      current_state = "thinking",
      current_version = V_CURRENT,
      boundary_reached = true,
      admission_status = "apply",
      effect_count = 2,
      post_admission_disposition = "effects-emitted(2)",
      legacy_log_outcome = "applied",
    })
  end,

  test_loop_plain_target_state_is_idempotent = function()
    assert_case({
      name = "loop-target-idempotent",
      current_state = "blocked",
      current_version = V_CURRENT,
      admission_status = "idempotent",
      legacy_log_outcome = "skip-idempotent(already at to_state)",
    })
  end,

  test_loop_plain_older_unmanaged_state_is_pending = function()
    assert_case({
      name = "loop-older-pending",
      current_state = nil,
      current_version = nil,
      admission_status = "pending",
      expected_exit_code = 1,
      legacy_log_outcome = "retry-pending(from-state marker not yet visible)",
    })
  end,

  test_loop_plain_newer_state_is_stale = function()
    assert_case({
      name = "loop-newer-stale",
      current_state = "ready",
      current_version = V_CURRENT,
      admission_status = "stale",
      legacy_log_outcome = "skip-advanced-or-diverged",
    })
  end,

  test_loop_plain_older_event_version_formats_stale_outcome = function()
    assert_case({
      name = "loop-older-event-version-stale",
      current_state = "ready",
      current_version = V_CURRENT,
      raw_event_version = V_OLDER,
      admission_status = "stale",
      catalog_cas_outcome = "skip-stale(incoming version < current marker version)",
      legacy_log_outcome = "skip-stale(incoming version < current marker version)",
    })
  end,

  test_loop_plain_unrelated_current_is_stale = function()
    assert_case({
      name = "loop-unrelated-stale",
      current_state = "closed-unmerged",
      current_version = V_CURRENT,
      admission_status = "stale",
      legacy_log_outcome = "skip-advanced-or-diverged",
    })
  end,

  test_loop_plain_raw_version_mismatch_has_no_overlay = function()
    assert_case({
      name = "loop-version-mismatch-no-overlay",
      current_state = "thinking",
      current_version = V_CURRENT,
      raw_event_version = V_DIFFERENT,
      boundary_reached = true,
      admission_status = "apply",
      effect_count = 2,
      post_admission_disposition = "effects-emitted(2)",
      legacy_log_outcome = "applied",
    })
  end,

  test_loop_plain_post_admission_round_idempotency_is_separate = function()
    assert_case({
      name = "loop-post-admission-round-idempotent",
      current_state = "thinking",
      current_version = V_CURRENT,
      round_marker_visible = true,
      boundary_reached = true,
      admission_status = "apply",
      post_admission_disposition = "round-idempotent",
      legacy_log_outcome = "skip-stale(converge round lineage already advanced)",
    })
  end,

  test_loop_plain_malformed_input_fails_closed_before_cas = function()
    assert_malformed_pre_cas()
  end,
}
