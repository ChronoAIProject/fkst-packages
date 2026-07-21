-- Non-circularity contract: production truth comes from the real timeout
-- reconcile department's named CAS probe and first effect-builder admission
-- boundary. Catalog evidence is copied from observed probe arguments, never
-- reconstructed from fixture fields. Pre-CAS guards, effects, and legacy CAS
-- logs are recorded as separate axes.

local catalog = require("devloop.restart_cas_catalog")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local requests_labels = require("devloop.requests.labels")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local transition_version = require("contract.transition_version")
local h = require("tests.devloop_helpers")
local restart_authority = require("core.restart_authority")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)
local reconcile_department = require("departments.reconcile.main")

local canonical_json = observation_support.canonical_json
local json_array = observation_support.json_array
local TIMEOUT_RECONCILE_CORPUS_PATH = "migration/intent_bounded_replay/corpus/timeout-reconcile.json"
local TIMEOUT_RECONCILE_NEW_TRACE_PATH = ".fkst/run/r9-timeout-reconcile-new-trace.json"

local OWNER = core.restart_package_name
local POLICY_ID = "cas.legacy_timeout_reconcile_v1"
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local SOURCE_REF = { kind = "external", ref = "owner/repo#issue/42" }
local V_OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local READY_ATTEMPT = V_EQUAL .. "/timeout/ready/3"
local V_ORDERING_EQUAL_CURRENT = V_EQUAL .. "/loop/01/timeout/ready/3"
local V_ORDERING_EQUAL_EVENT = V_EQUAL .. "/loop/1/timeout/ready/3"

local variants = {
  thinking = "thinking_to_blocked",
  ready = "ready_to_blocked",
  implementing = "implementing_to_blocked",
  reviewing = "reviewing_to_blocked",
  fixing = "fixing_to_blocked",
  ["merge-ready"] = "merge_ready_to_blocked",
  merging = "merging_to_blocked",
}

local function timeout_event(state_name, issue_version, round)
  local n = round or 3
  return {
    schema = "github-devloop.timeout-reconcile.v1",
    proposal_id = PROPOSAL_ID,
    state = state_name,
    issue_version = issue_version,
    round = n,
    dedup_key = "timeout-reconcile:" .. tostring(issue_version)
      .. "/timeout-reconcile/" .. tostring(state_name) .. "/" .. tostring(n),
    source_ref = SOURCE_REF,
  }
end

local function trusted_comment(body, created_at)
  return {
    body = body,
    author_login = core._test_bot_login,
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function observe_department(run)
  local probes = {}
  local decisions = {}
  local boundary_calls = {}
  local original_versioned = devloop_state.versioned_transition_status
  local original_decide = restart_effects.decide_transition
  local original_log_cas = devloop_logging.log_cas_decision
  local original_build_timeout = conv_reconcile.build_timeout_reconcile_comment_request

  devloop_state.versioned_transition_status = function()
    error("timeout-reconcile production used retired direct CAS", 0)
  end
  restart_effects.decide_transition = function(snapshot, intent)
    local decision = original_decide(snapshot, intent)
    table.insert(probes, {
      current = snapshot.current,
      from_states = { snapshot.current.state },
      to_state = intent.target,
      incoming_version = intent.incoming_version,
      target_version = intent.target_version,
      outcome = decision.status,
    })
    return decision
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
  conv_reconcile.build_timeout_reconcile_comment_request = function(
    repo,
    issue_number,
    reconcile,
    action,
    reason,
    version,
    fields
  )
    table.insert(boundary_calls, {
      repo = repo,
      issue_number = issue_number,
      reconcile = reconcile,
      action = action,
      reason = reason,
      version = version,
      fields = fields,
    })
    return original_build_timeout(repo, issue_number, reconcile, action, reason, version, fields)
  end

  local ok, result = pcall(run)
  conv_reconcile.build_timeout_reconcile_comment_request = original_build_timeout
  devloop_logging.log_cas_decision = original_log_cas
  restart_effects.decide_transition = original_decide
  devloop_state.versioned_transition_status = original_versioned
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

local function probe_variant(probe)
  if type(probe.from_states) ~= "table" or #probe.from_states ~= 1 or probe.to_state ~= "blocked" then
    return nil
  end
  return variants[probe.from_states[1]]
end

local function evidence_from_probe(probe)
  local variant_name = probe_variant(probe)
  local definition = catalog.definition(POLICY_ID)
  local variant = definition and definition.variants[variant_name]
  t.is_true(variant ~= nil, "observed timeout reconcile probe must select a catalog variant")
  t.eq(#variant.source_states, #probe.from_states, "catalog source-state count comes from probe signature")
  for index, source_state in ipairs(probe.from_states) do
    t.eq(variant.source_states[index], source_state, "catalog source state comes from probe signature")
  end
  t.eq(variant.target_state, probe.to_state, "catalog target state comes from probe signature")
  return {
    current = probe.current,
    variant = variant_name,
    incoming_version = probe.incoming_version,
    target_version = probe.target_version,
  }
end

local function emitted_state(result)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request" then
      return tostring(raised.payload and raised.payload.body or ""):match('state="([^"]+)"')
    end
  end
  return nil
end

local function observed_admission(probe, boundary_reached)
  if boundary_reached then
    return { status = "apply", reason_code = "apply" }
  end
  if probe.outcome == "pending" then
    return { status = "pending", reason_code = "source-marker-not-visible" }
  end
  if probe.outcome == "idempotent" then
    return { status = "idempotent", reason_code = "already-at-target" }
  end
  if probe.outcome == "stale" then
    if tostring(probe.incoming_version or "") ~= tostring(probe.current.version or "") then
      return { status = "stale", reason_code = "incoming-version-older" }
    end
    return { status = "stale", reason_code = "advanced-or-diverged" }
  end
  if probe.outcome ~= "apply" then
    error("timeout reconcile admission probe returned an unknown outcome: " .. tostring(probe.outcome))
  end
  error("timeout reconcile admission probe applied without reaching the effect boundary")
end

local function post_admission_disposition(result, boundary_reached)
  if not boundary_reached then
    return "not-admitted"
  end
  local state_name = emitted_state(result)
  if state_name ~= nil then
    return "effect-emitted(" .. state_name .. ")"
  end
  return "post-admission-no-effect"
end

local function run_real_department(event)
  local raises = {}
  local original_raise = raise
  raise = function(queue, payload)
    table.insert(raises, { queue = queue, payload = payload })
  end
  local ok, failure = pcall(reconcile_department.pipeline, {
    queue = "devloop_timeout_reconcile",
    payload = event,
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
    table.insert(comments, trusted_comment(core.state_marker(
      PROPOSAL_ID,
      fixture.current_state,
      fixture.current_version
    )))
  end
  if fixture.result_marker_visible then
    table.insert(comments, trusted_comment(conv_reconcile.timeout_reconcile_marker(
      PROPOSAL_ID,
      event.issue_version,
      event.state,
      event.round,
      "drop",
      { source_ref = SOURCE_REF }
    )))
  end
  return comments
end

local function frozen_old_apply_writes(boundary)
  local comment_request = conv_reconcile.build_timeout_reconcile_comment_request(
    boundary.repo,
    boundary.issue_number,
    boundary.reconcile,
    boundary.action,
    boundary.reason,
    boundary.version,
    boundary.fields
  )
  local label_request = requests_labels.build_state_label_request(
    boundary.repo,
    boundary.issue_number,
    "blocked",
    boundary.reconcile.proposal_id,
    boundary.version,
    require("devloop.base_ids").dedup_key({
      "timeout-reconcile",
      "label",
      tostring(boundary.reconcile.dedup_key),
    }),
    boundary.reconcile.source_ref
  )
  return {
    { queue = "github-proxy.github_issue_comment_request", payload = comment_request },
    { queue = "github-proxy.github_issue_label_request", payload = label_request },
  }
end

local function assert_bidirectional(actual, expected, field, context)
  t.eq(actual[field], expected[field], context .. ": shadow-to-production " .. field)
  t.eq(expected[field], actual[field], context .. ": production-to-shadow " .. field)
end

local function assert_timeout_shadow_case(fixture, probe, observed, decision)
  local sealed_snapshot = restart_authority.seal_snapshot({
    owner = OWNER,
    proposal_id = PROPOSAL_ID,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
  })
  local shadow, evidence = observe_shadow(function()
    return restart_authority.decide_transition(sealed_snapshot, {
      semantic_variant = "actionable_kickoff_timeout",
      target = "blocked",
      incoming_version = probe.incoming_version,
    })
  end)
  local production = {
    status = observed.status,
    reason_code = observed.reason_code,
    cas_outcome = decision.outcome,
  }

  assert_bidirectional(shadow, production, "status", fixture.name)
  assert_bidirectional(shadow, production, "reason_code", fixture.name)
  assert_bidirectional(shadow, production, "cas_outcome", fixture.name)
  t.eq(
    shadow.edge_id,
    OWNER .. "/ready/timeout/actionable_kickoff_timeout",
    fixture.name .. ": selected edge"
  )
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
  t.eq(evidence.current.state, fixture.current_state, fixture.name .. ": evidence current state")
  t.eq(evidence.current.version, fixture.current_version, fixture.name .. ": evidence raw current version")
  t.eq(evidence.variant, "ready_to_blocked", fixture.name .. ": evidence variant")
  t.eq(evidence.incoming_version, probe.incoming_version, fixture.name .. ": evidence incoming version")
  t.eq(evidence.target_version, nil, fixture.name .. ": evidence target version")
  t.eq(evidence.overlay_version, nil, fixture.name .. ": evidence overlay version")
end

local function assert_case(fixture)
  local event = fixture.event or timeout_event(
    fixture.event_state or "ready",
    fixture.event_version or fixture.current_version,
    fixture.round
  )
  h.mock_bot_env()
  if fixture.mock_issue ~= false then
    h.mock_issue_reconcile({}, fixture_comments(event, fixture))
  end

  local result, probes, decisions, boundary_calls = observe_department(function()
    return run_real_department(event)
  end)

  local admission_phase = #probes == 0 and "pre-cas" or "cas"
  t.eq(admission_phase, fixture.admission_phase or "cas", fixture.name .. ": admission phase")
  t.eq(#probes, admission_phase == "cas" and 1 or 0, fixture.name .. ": production CAS probe count")
  t.eq(#decisions, 1, fixture.name .. ": legacy CAS decision count")
  local decision = decisions[1]
  t.eq(decision.dept, "reconcile", fixture.name .. ": CAS decision department")
  t.is_true(type(decision.outcome) == "string", fixture.name .. ": legacy log outcome captured")
  t.is_true(type(decision.reason) == "string", fixture.name .. ": legacy log reason captured")

  local boundary_reached = #boundary_calls > 0
  t.eq(#boundary_calls, fixture.boundary_reached and 1 or 0, fixture.name .. ": admission boundary reach")
  local observed = nil
  local probe = nil
  if admission_phase == "cas" then
    probe = probes[1]
    t.eq(probe.from_states[1], event.state, fixture.name .. ": probe source state")
    t.eq(#probe.from_states, 1, fixture.name .. ": probe source-state count")
    t.eq(probe.to_state, "blocked", fixture.name .. ": probe target state")
    t.eq(probe.target_version, nil, fixture.name .. ": probe target version")

    observed = observed_admission(probe, boundary_reached)
    local evidence = evidence_from_probe(probe)
    t.eq(evidence.current, probe.current, fixture.name .. ": catalog current comes from probe")
    t.eq(evidence.incoming_version, probe.incoming_version, fixture.name .. ": catalog incoming comes from probe")
    t.eq(evidence.target_version, probe.target_version, fixture.name .. ": catalog target comes from probe")
    local actual = catalog.resolve(POLICY_ID, evidence, projection)
    t.eq(actual.status, observed.status, fixture.name .. ": admission status parity")
    t.eq(actual.reason_code, observed.reason_code, fixture.name .. ": admission reason parity")
    assert_timeout_shadow_case(fixture, probe, observed, decision)
    if fixture.admission_status ~= nil then
      t.eq(observed.status, fixture.admission_status, fixture.name .. ": observed admission status")
      t.eq(actual.status, fixture.admission_status, fixture.name .. ": catalog admission status")
    end
    if fixture.probe_incoming_is_derived then
      t.is_true(
        probe.incoming_version ~= event.issue_version,
        fixture.name .. ": probe incoming is production-derived, not the raw event version"
      )
    end
  else
    t.eq(boundary_reached, false, fixture.name .. ": pre-CAS input cannot reach admission boundary")
  end

  if boundary_reached then
    local boundary = boundary_calls[1]
    local probe = probes[1]
    t.eq(boundary.repo, "owner/repo", fixture.name .. ": boundary repo")
    t.eq(boundary.issue_number, "42", fixture.name .. ": boundary issue")
    t.eq(boundary.reconcile, event, fixture.name .. ": boundary event")
    t.eq(boundary.action, "drop", fixture.name .. ": boundary action")
    t.eq(boundary.version, probe.incoming_version, fixture.name .. ": boundary version is probe incoming")
  end

  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.name .. ": department exit code")
  t.eq(#result.raises, fixture.effect_count or 0, fixture.name .. ": captured effect count")
  if boundary_reached then
    t.eq(
      canonical_json(result.raises),
      canonical_json(frozen_old_apply_writes(boundary_calls[1])),
      fixture.name .. ": NEW full payload is byte-exact versus frozen OLD"
    )
  end
  t.eq(
    post_admission_disposition(result, boundary_reached),
    fixture.post_admission_disposition or "not-admitted",
    fixture.name .. ": post-admission disposition"
  )
  if fixture.legacy_log_outcome ~= nil then
    t.eq(decision.outcome, fixture.legacy_log_outcome, fixture.name .. ": legacy log outcome")
  end
  return {
    event = event,
    result = result,
    probe = probe,
    decision = decision,
    boundary = boundary_calls[1],
    observed = observed,
  }
end

local TRACE_EDGE_ID = OWNER .. "/ready/timeout/actionable_kickoff_timeout"
local TRACE_FIXTURES = {
  {
    fixture_id = "newer-source-marker-missing-pending",
    name = "r9-timeout-reconcile-newer-source-marker-missing",
    current_state = nil,
    current_version = nil,
    event_version = V_NEWER .. "/timeout/ready/3",
    admission_phase = "pre-cas",
    expected_exit_code = 1,
    legacy_log_outcome = "pending",
  },
  {
    fixture_id = "source-equal-apply",
    name = "r9-timeout-reconcile-source-equal-apply",
    current_state = "ready",
    current_version = READY_ATTEMPT,
    boundary_reached = true,
    admission_status = "apply",
    probe_incoming_is_derived = true,
    effect_count = 2,
    post_admission_disposition = "effect-emitted(blocked)",
    legacy_log_outcome = "applied",
  },
  {
    fixture_id = "source-older-stale",
    name = "r9-timeout-reconcile-source-older-stale",
    current_state = "ready",
    current_version = READY_ATTEMPT,
    event_version = V_OLDER .. "/timeout/ready/3",
    admission_phase = "pre-cas",
    legacy_log_outcome = "skip-stale(lineage-mismatch)",
  },
}

local function normalized_old_admission(fixture, production, incoming_version)
  if production.observed ~= nil then
    return production.observed.status, production.observed.reason_code,
      devloop_state.cas_outcome(production.probe.current, production.probe.outcome, incoming_version)
  end
  local outcome = production.decision.outcome
  if outcome == "pending" then
    return "pending", "source-marker-not-visible",
      devloop_state.cas_outcome({ state = nil, version = nil }, "pending", incoming_version)
  end
  if outcome:find("lineage-mismatch", 1, true) ~= nil then
    return "stale", "incoming-version-older",
      devloop_state.cas_outcome({ state = fixture.current_state, version = fixture.current_version }, "stale", incoming_version)
  end
  error("timeout reconcile trace saw unsupported pre-CAS outcome: " .. tostring(outcome), 0)
end

local function trace_artifact(corpus_hash, fixtures)
  return observation_support.admission_trace_artifact(
    "restart-timeout-reconcile-trace.v1",
    OWNER,
    "timeout-reconcile",
    corpus_hash,
    fixtures
  )
end

local function assert_timeout_reconcile_trace_equality()
  local corpus = json.decode(file.read(TIMEOUT_RECONCILE_CORPUS_PATH))
  local old_fixtures = json_array()
  local new_fixtures = json_array()
  for _, fixture in ipairs(TRACE_FIXTURES) do
    local production = assert_case(fixture)
    local incoming_version = production.boundary and production.boundary.version
      or conv_reconcile.timeout_reconcile_state_version(
        production.event.issue_version,
        production.event.state,
        production.event.round
      )
    local old_status, old_reason, old_cas_outcome = normalized_old_admission(
      fixture,
      production,
      incoming_version
    )
    local snapshot = restart_effects.seal_snapshot({
      owner = OWNER,
      entity = { kind = "issue", repo = "owner/repo", number = 42 },
      proposal_id = production.event.proposal_id,
      current = { state = fixture.current_state, version = fixture.current_version },
      snapshot_fingerprint = "r9-timeout-reconcile:" .. fixture.fixture_id,
      lock_epoch = "r9-timeout-reconcile:lock",
      generation = "r9-timeout-reconcile:generation",
    })
    local decided = restart_effects.decide_transition(snapshot, {
      semantic_variant = "actionable_kickoff_timeout",
      target = "blocked",
      incoming_version = incoming_version,
    })
    local new_writes = json_array()
    if decided.status == "apply" then
      local grant = restart_effects.mint_grant(
        snapshot,
        decided,
        "comment:issue:timeout-reconcile"
      )
      t.is_true(grant ~= nil, fixture.fixture_id .. ": NEW grant minted")
      local facade = restart_effect_facade.make({
        family = "timeout-reconcile",
        verify_grant = restart_effects.verify_grant,
        sink_inventory = require("core.restart.sink_inventory"),
      })
      local args = {
        issue = { repo = production.boundary.repo, number = production.boundary.issue_number },
        reconcile = production.boundary.reconcile,
        action = production.boundary.action,
        reason = production.boundary.reason,
        state_version = production.boundary.version,
        why_fields = production.boundary.fields,
      }
      for ordinal, effect_id in ipairs(decided.granted_effect_ids) do
        local emitted = facade.emit(grant, effect_id, snapshot, args)
        t.is_true(emitted ~= nil, fixture.fixture_id .. ": NEW facade emitted " .. effect_id)
        table.insert(new_writes, observation_support.admission_trace_write(
          ordinal,
          effect_id,
          emitted,
          "R9 timeout-reconcile trace"
        ))
      end
    end
    local old_writes = old_status == "apply"
      and observation_support.admission_trace_writes(
        production.result.raises,
        "R9 timeout-reconcile trace"
      )
      or json_array()
    table.insert(old_fixtures, observation_support.admission_trace_fixture(
      fixture, TRACE_EDGE_ID, old_status, old_reason, old_cas_outcome,
      decided.effect_entitlement_id, decided.granted_effect_ids, old_writes
    ))
    table.insert(new_fixtures, observation_support.admission_trace_fixture(
      fixture, TRACE_EDGE_ID, decided.status, decided.reason_code, decided.cas_outcome,
      decided.effect_entitlement_id, decided.granted_effect_ids, new_writes
    ))
  end

  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  local new_trace = trace_artifact(corpus.artifact_sha256, new_fixtures)
  t.eq(canonical_json(old_trace), canonical_json(new_trace),
    "R9 timeout-reconcile OLD and NEW semantic trace")
  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 timeout-reconcile trace could not create its artifact directory", 0)
  end
  file.write(TIMEOUT_RECONCILE_NEW_TRACE_PATH, canonical_json(new_trace) .. "\n")
  t.eq(canonical_json(old_trace), canonical_json(corpus),
    "R9 timeout-reconcile OLD observation corpus")
  t.eq(canonical_json(new_trace), canonical_json(corpus),
    "R9 timeout-reconcile NEW semantic trace")
end

return {
  test_r9_timeout_reconcile_old_equals_new_admission_trace = function()
    assert_timeout_reconcile_trace_equality()
  end,

  test_timeout_reconcile_source_applies_at_effect_builder_boundary = function()
    assert_case({
      name = "timeout-reconcile-source-apply",
      current_state = "ready",
      current_version = READY_ATTEMPT,
      boundary_reached = true,
      admission_status = "apply",
      probe_incoming_is_derived = true,
      effect_count = 2,
      post_admission_disposition = "effect-emitted(blocked)",
      legacy_log_outcome = "applied",
    })
  end,

  test_timeout_reconcile_safe_equal_raw_different_uses_observed_probe_evidence = function()
    t.is_true(
      V_ORDERING_EQUAL_CURRENT ~= V_ORDERING_EQUAL_EVENT,
      "timeout-reconcile-safe-equal: fixture versions must be byte-different"
    )
    t.eq(
      transition_version.strip_suffixes(V_ORDERING_EQUAL_CURRENT),
      transition_version.strip_suffixes(V_ORDERING_EQUAL_EVENT),
      "timeout-reconcile-safe-equal: fixture versions must share canonical lineage"
    )
    assert_case({
      name = "timeout-reconcile-safe-equal-raw-different",
      current_state = "ready",
      current_version = V_ORDERING_EQUAL_CURRENT,
      event_version = V_ORDERING_EQUAL_EVENT,
      boundary_reached = true,
      admission_status = "apply",
      probe_incoming_is_derived = true,
      effect_count = 2,
      post_admission_disposition = "effect-emitted(blocked)",
      legacy_log_outcome = "applied",
    })
  end,

  test_timeout_reconcile_visible_result_marker_is_pre_cas_effect_idempotency = function()
    assert_case({
      name = "timeout-reconcile-result-visible",
      current_state = "ready",
      current_version = READY_ATTEMPT,
      result_marker_visible = true,
      admission_phase = "pre-cas",
      legacy_log_outcome = "skip-idempotent(timeout reconcile marker already visible)",
    })
  end,

  test_timeout_reconcile_target_current_is_pre_cas_from_state_stale = function()
    assert_case({
      name = "timeout-reconcile-target-current",
      current_state = "blocked",
      current_version = READY_ATTEMPT,
      event_state = "ready",
      event_version = READY_ATTEMPT,
      admission_phase = "pre-cas",
      legacy_log_outcome = "skip-stale(state-advanced)",
    })
  end,

  test_timeout_reconcile_terminal_current_is_pre_cas_idempotent = function()
    assert_case({
      name = "timeout-reconcile-terminal-current",
      current_state = "merged",
      current_version = READY_ATTEMPT,
      event_state = "ready",
      event_version = READY_ATTEMPT,
      admission_phase = "pre-cas",
      legacy_log_outcome = "skip-idempotent(already terminal)",
    })
  end,

  test_timeout_reconcile_older_event_is_pre_cas_lineage_stale = function()
    assert_case({
      name = "timeout-reconcile-older-event",
      current_state = "ready",
      current_version = READY_ATTEMPT,
      event_version = V_OLDER .. "/timeout/ready/3",
      admission_phase = "pre-cas",
      legacy_log_outcome = "skip-stale(lineage-mismatch)",
    })
  end,

  test_timeout_reconcile_newer_event_is_pre_cas_lineage_stale = function()
    assert_case({
      name = "timeout-reconcile-newer-event",
      current_state = "ready",
      current_version = READY_ATTEMPT,
      event_version = V_NEWER .. "/timeout/ready/3",
      admission_phase = "pre-cas",
      legacy_log_outcome = "skip-stale(lineage-mismatch)",
    })
  end,

  test_timeout_reconcile_unrelated_current_is_pre_cas_stale = function()
    assert_case({
      name = "timeout-reconcile-unrelated-current",
      current_state = "thinking",
      current_version = READY_ATTEMPT,
      event_state = "ready",
      event_version = READY_ATTEMPT,
      admission_phase = "pre-cas",
      legacy_log_outcome = "skip-stale(state-advanced)",
    })
  end,

  test_timeout_reconcile_missing_current_is_pre_cas_pending = function()
    assert_case({
      name = "timeout-reconcile-current-missing",
      current_state = nil,
      current_version = nil,
      event_state = "ready",
      event_version = READY_ATTEMPT,
      admission_phase = "pre-cas",
      expected_exit_code = 1,
      legacy_log_outcome = "pending",
    })
  end,

  test_timeout_reconcile_malformed_payload_fails_closed_before_cas = function()
    local event = timeout_event("ready", 42)
    assert_case({
      name = "timeout-reconcile-malformed-version",
      event = event,
      mock_issue = false,
      admission_phase = "pre-cas",
      legacy_log_outcome = "skip-foreign(proposal_id)",
    })
  end,
}
