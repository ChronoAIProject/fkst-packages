-- Non-circularity contract: production truth comes from the real observe_issue
-- department's CAS probe and the issue-claim admission boundary. Effects and
-- legacy CAS logs are recorded as separate post-admission observations. This
-- test never computes the expected result with a devloop.state transition helper.
-- Inputs that never reach the probe are pre-CAS admissions and are not resolved
-- through the catalog.

local catalog = require("devloop.restart_cas_catalog")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local devloop_claims = require("devloop.claims")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local dispatch_live_run = require("devloop.dispatch_live_run")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local restart_authority = require("core.restart_authority")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local canonical_json = observation_support.canonical_json
local json_array = observation_support.json_array
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)
local observe_issue_department = require("departments.observe_issue.main")

local OWNER = core.restart_package_name
local POLICY_ID = "cas.legacy_observe_issue_entry_v1"
local VARIANT = "unmanaged_to_thinking"
local V_OLDER = "github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local ISSUE_V_OLDER = "owner/repo#issue#42@2026-06-02T01:02:03Z"
local ISSUE_V_EQUAL = "owner/repo#issue#42@2026-06-03T01:02:03Z"
local V_ORDERING_EQUAL_CURRENT = V_EQUAL .. "/loop/01"
local V_ORDERING_EQUAL_INCOMING = V_EQUAL .. "/loop/1"
local OBSERVE_ISSUE_ENTRY_CORPUS_PATH = "migration/intent_bounded_replay/corpus/observe-issue-entry.json"
local OBSERVE_ISSUE_ENTRY_NEW_TRACE_PATH = ".fkst/run/r9-observe-issue-entry-new-trace.json"
local OLD_OBSERVATION_INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local INTAKE_DECISION_REASONS = {
  ["unsupported event payload"] = true,
  ["issue is not open"] = true,
  ["fkst-dev:enabled label is absent"] = true,
  ["fkst-dev:hold label is present"] = true,
  ["current marker is not an unmanaged start"] = true,
  ["unmanaged state marker pending for observe"] = true,
  ["starting consensus for opted-in issue"] = true,
}

local function observe_department(run, fixture)
  local probes = {}
  local decisions = {}
  local boundary_calls = {}
  local original_versioned = devloop_state.versioned_transition_status
  local original_log_cas = devloop_logging.log_cas_decision
  local original_claim_issue = devloop_claims.claim_issue_for_management
  -- Keep each fixture independent from the process-wide live-run registry.
  -- Managed OLD-truth fixtures opt into the exact live consensus fact that lets
  -- replay/timeout fall through to this shared CAS site.
  local original_dispatch_live_run_dedup = dispatch_live_run.dispatch_live_run_dedup
  dispatch_live_run.dispatch_live_run_dedup = function()
    return fixture ~= nil and fixture.live_thinking == true
  end

  devloop_state.versioned_transition_status = function(current, from_states, to_state, incoming_version, target_version)
    local outcome = original_versioned(current, from_states, to_state, incoming_version, target_version)
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
  devloop_logging.log_cas_decision = function(dept, proposal_id, current, from_state, to_state, outcome, reason)
    if dept == "observe_issue"
      and from_state == "unmanaged"
      and to_state == "thinking"
      and INTAKE_DECISION_REASONS[reason] == true then
      table.insert(decisions, {
        dept = dept,
        proposal_id = proposal_id,
        current = current,
        from_state = from_state,
        to_state = to_state,
        outcome = outcome,
        reason = reason,
      })
    end
    return original_log_cas(dept, proposal_id, current, from_state, to_state, outcome, reason)
  end
  devloop_claims.claim_issue_for_management = function(M, dept, repo, issue_number, current, proposal_id)
    local outcome = original_claim_issue(M, dept, repo, issue_number, current, proposal_id)
    table.insert(boundary_calls, {
      dept = dept,
      repo = repo,
      issue_number = issue_number,
      current = current,
      proposal_id = proposal_id,
      outcome = outcome,
    })
    return outcome
  end

  local ok, result = pcall(run)
  dispatch_live_run.dispatch_live_run_dedup = original_dispatch_live_run_dedup
  devloop_claims.claim_issue_for_management = original_claim_issue
  devloop_logging.log_cas_decision = original_log_cas
  devloop_state.versioned_transition_status = original_versioned
  if not ok then
    error(result, 0)
  end
  return result, probes, decisions, boundary_calls
end

local function evidence_from_probe(probe)
  return {
    current = probe.current,
    variant = VARIANT,
    source_states = probe.from_states,
    target_state = probe.to_state,
    incoming_version = probe.incoming_version,
    target_version = probe.target_version,
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

local function emitted_state(result)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request" then
      return tostring(raised.payload and raised.payload.body or ""):match('state="([^"]+)"')
    end
  end
  return nil
end

local function observed_admission(probe, boundary_reached, decision)
  if probe.outcome == "pending" then
    return { status = "pending", reason_code = "source-marker-not-visible" }
  end
  if probe.outcome == "idempotent" then
    return { status = "idempotent", reason_code = "already-at-target" }
  end
  if probe.outcome == "stale" then
    if decision ~= nil
      and decision.outcome == "skip-stale(incoming version < current marker version)" then
      return { status = "stale", reason_code = "incoming-version-older" }
    end
    return { status = "stale", reason_code = "advanced-or-diverged" }
  end
  if probe.outcome ~= "apply" then
    error("observe-issue-entry admission probe returned an unknown outcome: " .. tostring(probe.outcome))
  end
  if boundary_reached then
    return { status = "apply", reason_code = "apply" }
  end
  error("observe-issue-entry admission apply did not reach the issue-claim guard")
end

local function post_admission_disposition(result, decision, boundary_reached)
  local state = emitted_state(result)
  if state ~= nil then
    return "effect-emitted(" .. state .. ")"
  end
  if not boundary_reached then
    return "not-admitted"
  end
  local outcome = tostring(decision and decision.outcome or "")
  if outcome:find("claim", 1, true) ~= nil then
    return "claim-deferred"
  end
  return "post-admission-no-effect"
end

local function run_real_department(event)
  local raises = {}
  local original_raise = raise
  raise = function(queue, payload)
    table.insert(raises, { queue = queue, payload = payload })
  end
  local ok, failure = pcall(observe_issue_department.pipeline, {
    queue = "devloop_observe_issue",
    payload = event,
    ts = "2026-06-03T01:02:04Z",
  })
  raise = original_raise
  return {
    exit_code = ok and 0 or 1,
    error = ok and nil or tostring(failure),
    raises = raises,
  }
end

local function state_comment(proposal_id, state, version)
  return {
    body = core.state_marker(proposal_id, state, version),
    author_login = "fkst-test-bot",
    created_at = "2099-01-01T00:00:00Z",
  }
end

local function mock_current_issue(event, fixture)
  local proposal_id = "github-devloop/issue/owner/repo/42"
  local comments = {}
  local labels = { "fkst-dev:enabled" }
  if fixture.current_state ~= nil then
    table.insert(comments, state_comment(proposal_id, fixture.current_state, fixture.current_version))
    table.insert(labels, "fkst-dev:" .. fixture.current_state)
  end
  h.mock_issue_state(labels, "OPEN", comments)
  for _ = 1, fixture.context_bundle_builds or 1 do
    h.mock_context_bundle(event)
  end
end

local function assert_catalog_matches_observed_decision(fixture)
  local event = h.issue({ dedup_key = fixture.incoming_version })
  mock_current_issue(event, fixture)

  local result, probes, decisions, boundary_calls = observe_department(function()
    return run_real_department(event)
  end, fixture)

  t.is_true(#probes <= 1, fixture.name .. ": real department CAS probe count must be at most one")
  local boundary_reached = #boundary_calls > 0
  if #probes == 0 then
    t.eq(
      result.exit_code,
      fixture.expected_exit_code or 0,
      fixture.name .. ": pre-CAS department exit code: " .. tostring(result.error)
    )
    t.eq(#boundary_calls, 0, fixture.name .. ": pre-CAS input must not reach the admission boundary")
    local decision = decisions[#decisions]
    local disposition = post_admission_disposition(result, decision, false)
    t.eq(disposition, fixture.post_admission_disposition or "not-admitted", fixture.name .. ": pre-CAS disposition")
    return "pre-cas"
  end

  local probe = probes[1]
  t.eq(probe.current.state, fixture.current_state, fixture.name .. ": probe current state")
  t.eq(probe.current.version, fixture.current_version, fixture.name .. ": probe current version")
  t.eq(probe.from_states[1], "unmanaged", fixture.name .. ": probe source state")
  t.eq(#probe.from_states, 1, fixture.name .. ": probe source state count")
  t.eq(probe.to_state, "thinking", fixture.name .. ": probe target state")
  t.eq(probe.incoming_version, fixture.incoming_version, fixture.name .. ": probe incoming version")
  t.eq(probe.target_version, nil, fixture.name .. ": probe target version")

  local definition = catalog.definition(POLICY_ID)
  local variant = definition and definition.variants and definition.variants[VARIANT]
  t.is_true(variant ~= nil, fixture.name .. ": catalog variant exists")
  t.eq(#variant.source_states, #probe.from_states, fixture.name .. ": catalog source state count matches probe")
  for index, source_state in ipairs(probe.from_states) do
    t.eq(variant.source_states[index], source_state, fixture.name .. ": catalog source state matches probe")
  end
  t.eq(variant.target_state, probe.to_state, fixture.name .. ": catalog target state matches probe")
  t.eq(variant.target_version, probe.target_version, fixture.name .. ": catalog target version matches probe")

  t.eq(#decisions, 1, fixture.name .. ": structured CAS decision count")
  local decision = decisions[1]
  t.eq(decision.dept, "observe_issue", fixture.name .. ": CAS decision department")
  t.eq(decision.from_state, "unmanaged", fixture.name .. ": logged source state")
  t.eq(decision.to_state, "thinking", fixture.name .. ": logged target state")
  t.is_true(type(decision.outcome) == "string", fixture.name .. ": legacy log outcome captured")
  t.is_true(type(decision.reason) == "string", fixture.name .. ": legacy log reason captured")

  local expected_boundary_reached = fixture.boundary_reached
  if expected_boundary_reached == nil then
    expected_boundary_reached = probe.outcome == "apply"
  end
  t.eq(#boundary_calls, expected_boundary_reached and 1 or 0, fixture.name .. ": admission boundary reach")
  if boundary_reached then
    local boundary = boundary_calls[1]
    t.eq(boundary.dept, "observe_issue", fixture.name .. ": claim boundary department")
    t.eq(boundary.repo, event.repo, fixture.name .. ": claim boundary repo")
    t.eq(boundary.issue_number, event.number, fixture.name .. ": claim boundary issue")
    t.eq(boundary.proposal_id, "github-devloop/issue/owner/repo/42", fixture.name .. ": claim boundary proposal")
    t.eq(boundary.outcome, true, fixture.name .. ": claim boundary outcome")
  end

  local observed = observed_admission(probe, boundary_reached, decision)
  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.name .. ": department exit code")
  if fixture.effect_count ~= nil then
    t.eq(#result.raises, fixture.effect_count, fixture.name .. ": captured effect count")
  end

  local disposition = post_admission_disposition(result, decision, boundary_reached)
  t.eq(disposition, fixture.post_admission_disposition or "not-admitted", fixture.name .. ": post-admission disposition")
  if fixture.legacy_log_outcome ~= nil then
    t.eq(decision.outcome, fixture.legacy_log_outcome, fixture.name .. ": legacy log outcome")
  end

  local actual = catalog.resolve(POLICY_ID, evidence_from_probe(probe), projection)
  t.eq(actual.status, observed.status, fixture.name .. ": admission status parity")
  t.eq(actual.reason_code, observed.reason_code, fixture.name .. ": admission reason parity")
  return {
    event = event,
    result = result,
    probe = probe,
    decision = decision,
    observed = observed,
  }
end

local function assert_bidirectional(actual, expected, field, context)
  t.eq(actual[field], expected[field], context .. ": shadow-to-production " .. field)
  t.eq(expected[field], actual[field], context .. ": production-to-shadow " .. field)
end

local function assert_observe_issue_entry_shadow_case(fixture)
  local production = assert_catalog_matches_observed_decision(fixture)
  t.eq(type(production), "table", fixture.name .. ": production reaches CAS")

  local edge_id = OWNER .. "/thinking/entry/unmanaged_issue"
  local sealed_snapshot = restart_authority.seal_snapshot({
    owner = OWNER,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
  })
  local intent = {
    semantic_variant = "unmanaged_issue",
    source_boundary = "github-proxy.github_entity_changed",
    target = "thinking",
    incoming_version = fixture.incoming_version,
  }

  local shadow, evidence = observe_shadow(function()
    return restart_authority.decide_transition(sealed_snapshot, intent)
  end)
  local observed = {
    status = production.observed.status,
    reason_code = production.observed.reason_code,
    cas_outcome = production.decision.outcome,
  }

  assert_bidirectional(shadow, observed, "status", fixture.name)
  assert_bidirectional(shadow, observed, "reason_code", fixture.name)
  assert_bidirectional(shadow, observed, "cas_outcome", fixture.name)
  t.eq(shadow.edge_id, edge_id, fixture.name .. ": selected edge")
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
  t.eq(evidence.current.state, fixture.current_state, fixture.name .. ": evidence current state")
  t.eq(evidence.current.version, fixture.current_version, fixture.name .. ": evidence raw current version")
  t.eq(evidence.variant, VARIANT, fixture.name .. ": evidence variant")
  t.eq(evidence.incoming_version, fixture.incoming_version, fixture.name .. ": evidence incoming version")
  t.eq(evidence.target_version, nil, fixture.name .. ": evidence target version")
  t.eq(evidence.overlay_version, nil, fixture.name .. ": evidence overlay version")
end

local TRACE_EDGE_ID = OWNER .. "/thinking/entry/unmanaged_issue"
local TRACE_FIXTURES = {
  {
    fixture_id = "advanced-source-stale",
    name = "r9-observe-issue-entry-advanced-source-stale",
    old_observation_name = "declined-state-advanced",
    current_state = "declined",
    current_version = V_EQUAL,
    incoming_version = ISSUE_V_EQUAL,
    legacy_log_outcome = "skip-advanced-or-diverged",
    legacy_log_reason = "current marker is not an unmanaged start",
    cas_status = "stale",
    reason_code = "advanced-or-diverged",
    effect_count = 0,
    effect_entitlement_id = nil,
    granted_effect_ids = {},
    managed_old_trace = true,
  },
  {
    fixture_id = "thinking-idempotent-reemit",
    name = "r9-observe-issue-entry-thinking-idempotent-reemit",
    old_observation_name = "thinking-live-idempotent-reemit",
    current_state = "thinking",
    current_version = V_EQUAL,
    incoming_version = ISSUE_V_EQUAL,
    live_thinking = true,
    boundary_reached = true,
    context_bundle_builds = 2,
    effect_count = 3,
    post_admission_disposition = "effect-emitted(thinking)",
    legacy_log_outcome = "skip-idempotent(already at to_state)",
    legacy_log_reason = "starting consensus for opted-in issue",
    cas_status = "idempotent",
    reason_code = "already-thinking-reemit",
    effect_entitlement_id = TRACE_EDGE_ID .. "/idempotent",
    granted_effect_ids = {
      "consensus.proposal",
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
    },
    include_consensus_effect = true,
    managed_old_trace = true,
  },
  {
    fixture_id = "thinking-older-version-stale",
    name = "r9-observe-issue-entry-thinking-older-version-stale",
    old_observation_name = "thinking-older-event",
    current_state = "thinking",
    current_version = V_EQUAL,
    incoming_version = ISSUE_V_OLDER,
    live_thinking = true,
    legacy_log_outcome = "skip-stale(incoming version < current marker version)",
    legacy_log_reason = "current marker is not an unmanaged start",
    cas_status = "stale",
    reason_code = "incoming-version-older",
    effect_count = 0,
    effect_entitlement_id = nil,
    granted_effect_ids = {},
    managed_old_trace = true,
  },
  {
    fixture_id = "unmanaged-source-apply",
    name = "r9-observe-issue-entry-unmanaged-source-apply",
    old_observation_name = "unmanaged-ingress-apply",
    current_state = nil,
    current_version = nil,
    incoming_version = V_EQUAL,
    effect_count = 3,
    post_admission_disposition = "effect-emitted(thinking)",
    legacy_log_outcome = "applied",
    legacy_log_reason = "starting consensus for opted-in issue",
    cas_status = "apply",
    reason_code = "apply",
    effect_entitlement_id = TRACE_EDGE_ID .. "/apply",
    granted_effect_ids = {
      "github-proxy.github_issue_comment_request",
      "github-proxy.github_issue_label_request",
    },
    verify_existing_new_facade = true,
  },
}

local ADMISSION_EFFECT_IDS = {
  ["github-proxy.github_issue_comment_request"] = true,
  ["github-proxy.github_issue_label_request"] = true,
}

local OLD_EFFECT_SHAPES = {
  ["consensus.proposal"] = {
    effect_id = "queue:consensus.proposal",
    sink_kind = "queue",
    authority_class = "lifecycle-authoritative",
  },
  ["github-proxy.github_issue_comment_request"] = {
    effect_id = "comment:issue:thinking-state",
    sink_kind = "comment",
    authority_class = "lifecycle-authoritative",
  },
  ["github-proxy.github_issue_label_request"] = {
    effect_id = "label:issue:thinking-state",
    sink_kind = "label",
    authority_class = "lifecycle-authoritative",
  },
}

local function admission_trace_writes(raises)
  local scoped = json_array()
  for _, raised in ipairs(raises or {}) do
    if ADMISSION_EFFECT_IDS[raised.queue] == true then
      table.insert(scoped, raised)
    end
  end
  return observation_support.admission_trace_writes(scoped, "R9 observe-issue-entry admission trace")
end

local function raised_payload(result, queue)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue then
      return raised.payload
    end
  end
  return nil
end

local function trace_fixture(fixture, decision, writes)
  return observation_support.admission_trace_fixture(
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

local function trace_artifact(corpus_hash, fixtures)
  return observation_support.admission_trace_artifact(
    "restart-observe-issue-entry-trace.v1",
    OWNER,
    "observe-issue-entry",
    corpus_hash,
    fixtures
  )
end

local function frozen_old_observation(observation_name)
  local inventory = json.decode(file.read(OLD_OBSERVATION_INVENTORY_PATH))
  local selected = nil
  local needle = "/" .. observation_name .. "/"
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    local site = record.site or {}
    if site.path == "packages/github-devloop/departments/observe_issue/main.lua"
      and site.symbol == "process_issue_event"
      and site.ordinal == "versioned_transition_status:unmanaged->thinking"
      and tostring(record.observation_id or ""):find(needle, 1, true) ~= nil then
      t.eq(selected, nil, observation_name .. ": frozen OLD observation is unique")
      selected = record
    end
  end
  t.is_true(selected ~= nil, observation_name .. ": frozen OLD observation exists")
  return selected
end

local function assert_frozen_old_trace(fixture, production)
  local expected = frozen_old_observation(fixture.old_observation_name)
  local expected_outcome = expected.old_outcome
  local expected_inputs = expected.old_inputs
  t.eq(production.probe.current.state, expected_inputs.current_fact.state, fixture.fixture_id .. ": OLD current state")
  t.eq(production.probe.current.version, expected_inputs.current_fact.version, fixture.fixture_id .. ": OLD current version")
  t.eq(production.probe.incoming_version, expected_inputs.incoming_version, fixture.fixture_id .. ": OLD incoming version")
  t.eq(production.probe.outcome, expected_outcome.status, fixture.fixture_id .. ": OLD CAS status")
  t.eq(production.decision.outcome, expected_outcome.cas_outcome, fixture.fixture_id .. ": OLD CAS outcome")
  t.eq(production.decision.reason, fixture.legacy_log_reason, fixture.fixture_id .. ": OLD log reason")
  t.eq(expected_outcome.reason_code, fixture.reason_code, fixture.fixture_id .. ": OLD reason code")
  t.eq(#production.result.raises, #expected_outcome.observable_writes, fixture.fixture_id .. ": OLD write multiplicity")
  t.eq(#production.result.raises, #expected_outcome.emitted_effects, fixture.fixture_id .. ": OLD effect multiplicity")
  for ordinal, raised in ipairs(production.result.raises) do
    local expected_write = expected_outcome.observable_writes[ordinal]
    local expected_effect = expected_outcome.emitted_effects[ordinal]
    local shape = OLD_EFFECT_SHAPES[raised.queue]
    t.is_true(shape ~= nil, fixture.fixture_id .. ": OLD effect shape is classified at ordinal " .. tostring(ordinal))
    t.eq(raised.queue, expected_write.queue, fixture.fixture_id .. ": OLD queue order at ordinal " .. tostring(ordinal))
    t.eq(canonical_json(raised.payload), canonical_json(expected_write.payload), fixture.fixture_id .. ": OLD payload at ordinal " .. tostring(ordinal))
    t.eq(expected_effect.ordinal, ordinal, fixture.fixture_id .. ": OLD effect ordinal")
    t.eq(expected_effect.effect_id, shape.effect_id, fixture.fixture_id .. ": OLD effect id")
    t.eq(expected_effect.sink_kind, shape.sink_kind, fixture.fixture_id .. ": OLD sink kind")
    t.eq(expected_effect.authority_class, shape.authority_class, fixture.fixture_id .. ": OLD authority class")
  end
  local traced_writes = observation_support.admission_trace_writes(
    production.result.raises,
    fixture.fixture_id .. ": managed OLD trace"
  )
  t.eq(#traced_writes, #expected_outcome.observable_writes, fixture.fixture_id .. ": OLD traced write multiplicity")
  for ordinal, write in ipairs(traced_writes) do
    t.eq(write.ordinal, ordinal, fixture.fixture_id .. ": OLD traced ordinal")
    t.eq(write.effect_id, expected_outcome.observable_writes[ordinal].queue, fixture.fixture_id .. ": OLD traced effect id")
  end
end

local function frozen_trace_writes(fixture)
  local expected = frozen_old_observation(fixture.old_observation_name)
  local raises = json_array()
  for _, write in ipairs(expected.old_outcome.observable_writes or {}) do
    table.insert(raises, { queue = write.queue, payload = write.payload })
  end
  return observation_support.admission_trace_writes(raises, fixture.fixture_id .. ": frozen OLD trace")
end

local function new_trace_fixture(fixture, production)
  local proposal = raised_payload(production.result, "consensus.proposal")
  t.is_true(proposal ~= nil, fixture.fixture_id .. ": OLD proposal observed")
  local snapshot = restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "issue", repo = "owner/repo", number = 42 },
    proposal_id = proposal.proposal_id,
    current = {
      state = fixture.current_state,
      -- Entry has no source marker; bind the grant to the incoming lifecycle effect version.
      version = fixture.incoming_version,
    },
    snapshot_fingerprint = "r9-observe-issue-entry:" .. fixture.fixture_id,
    lock_epoch = "r9-observe-issue-entry:lock",
    generation = "r9-observe-issue-entry:generation",
  })
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "unmanaged_issue",
    source_boundary = "github-proxy.github_entity_changed",
    target = "thinking",
    incoming_version = fixture.incoming_version,
  })
  t.eq(decided.status, "apply", fixture.fixture_id .. ": NEW admission status " .. tostring(decided.reason_code))
  t.eq(decided.effect_entitlement_id, TRACE_EDGE_ID .. "/apply", fixture.fixture_id .. ": NEW entitlement")
  t.eq(#decided.granted_effect_ids, 2, fixture.fixture_id .. ": NEW granted effect count")
  local grant = restart_effects.mint_grant(snapshot, decided, "comment:issue:thinking-state")
  t.is_true(grant ~= nil, fixture.fixture_id .. ": NEW grant minted")
  local facade = restart_effect_facade.make({
    family = "observe-issue-entry",
    verify_grant = restart_effects.verify_grant,
    sink_inventory = require("core.restart.sink_inventory"),
  })
  local writes = json_array()
  local args = {
    core = core,
    issue = production.event,
    proposal = proposal,
  }
  for ordinal, effect_id in ipairs(decided.granted_effect_ids) do
    local emitted = facade.emit(grant, effect_id, snapshot, args)
    t.is_true(emitted ~= nil, fixture.fixture_id .. ": NEW facade emitted " .. effect_id)
    table.insert(writes, observation_support.admission_trace_write(ordinal, effect_id, emitted))
  end
  return trace_fixture(fixture, decided, writes)
end

local function assert_observe_issue_entry_trace_equality()
  os.remove(OBSERVE_ISSUE_ENTRY_NEW_TRACE_PATH)
  local corpus = json.decode(file.read(OBSERVE_ISSUE_ENTRY_CORPUS_PATH))
  local old_fixtures = json_array()
  for _, fixture in ipairs(TRACE_FIXTURES) do
    local production = nil
    local old_writes = nil
    if fixture.managed_old_trace then
      old_writes = frozen_trace_writes(fixture)
    else
      production = assert_catalog_matches_observed_decision(fixture)
      old_writes = admission_trace_writes(production.result.raises)
    end
    t.eq(#old_writes, #fixture.granted_effect_ids, fixture.fixture_id .. ": OLD admission write count")
    local old_fixture = trace_fixture(fixture, {
      status = fixture.cas_status,
      reason_code = fixture.reason_code,
      cas_outcome = fixture.legacy_log_outcome,
      effect_entitlement_id = fixture.effect_entitlement_id,
      granted_effect_ids = fixture.granted_effect_ids,
    }, old_writes)
    table.insert(old_fixtures, old_fixture)
    if fixture.verify_existing_new_facade then
      local new_fixture = new_trace_fixture(fixture, production)
      t.eq(canonical_json(old_fixture), canonical_json(new_fixture), fixture.fixture_id .. ": existing OLD and NEW semantic trace")
    end
  end

  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  t.eq(canonical_json(old_trace), canonical_json(corpus), "R9 observe-issue-entry OLD observation corpus")
end

local function trace_fixture_by_id(fixture_id)
  for _, fixture in ipairs(TRACE_FIXTURES) do
    if fixture.fixture_id == fixture_id then
      return fixture
    end
  end
  error("missing observe-issue-entry trace fixture: " .. tostring(fixture_id), 0)
end

local function assert_managed_old_trace_case(fixture_id)
  local fixture = trace_fixture_by_id(fixture_id)
  local production = assert_catalog_matches_observed_decision(fixture)
  assert_frozen_old_trace(fixture, production)
end

local function assert_malformed_fails_closed_before_cas()
  local event = h.issue()
  event.updated_at = nil

  local result, probes, decisions, boundary_calls = observe_department(function()
    return run_real_department(event)
  end)

  t.eq(result.exit_code, 0, "observe-issue-entry-malformed: department rejects cleanly")
  t.eq(#probes, 0, "observe-issue-entry-malformed: production rejects before CAS")
  t.eq(#boundary_calls, 0, "observe-issue-entry-malformed: admission boundary is not reached")
  t.eq(#decisions, 1, "observe-issue-entry-malformed: rejection decision count")

end

return {
  test_observe_issue_entry_unmanaged_source_is_admitted_and_emits = function()
    assert_observe_issue_entry_shadow_case({
      name = "observe-issue-entry-source-apply",
      current_state = nil,
      current_version = nil,
      incoming_version = V_EQUAL,
      effect_count = 3,
      post_admission_disposition = "effect-emitted(thinking)",
      legacy_log_outcome = "applied",
    })
  end,

  test_observe_issue_entry_managed_thinking_idempotent_reemits_full_old_trace = function()
    assert_managed_old_trace_case("thinking-idempotent-reemit")
  end,

  test_observe_issue_entry_managed_thinking_older_event_matches_full_old_trace = function()
    assert_managed_old_trace_case("thinking-older-version-stale")
  end,

  test_observe_issue_entry_managed_advanced_state_matches_full_old_trace = function()
    assert_managed_old_trace_case("advanced-source-stale")
  end,

  test_observe_issue_entry_target_state_is_pre_cas = function()
    assert_catalog_matches_observed_decision({
      name = "observe-issue-entry-target-idempotent",
      current_state = "thinking",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
    })
  end,

  test_observe_issue_entry_older_event_is_pre_cas = function()
    assert_catalog_matches_observed_decision({
      name = "observe-issue-entry-older-stale",
      current_state = "thinking",
      current_version = V_EQUAL,
      incoming_version = V_OLDER,
    })
  end,

  test_observe_issue_entry_newer_event_at_target_is_pre_cas = function()
    assert_catalog_matches_observed_decision({
      name = "observe-issue-entry-newer-target-idempotent",
      current_state = "thinking",
      current_version = V_EQUAL,
      incoming_version = V_NEWER,
    })
  end,

  test_observe_issue_entry_ordering_equal_raw_different_is_pre_cas = function()
    t.is_true(
      V_ORDERING_EQUAL_CURRENT ~= V_ORDERING_EQUAL_INCOMING,
      "observe-issue-entry-ordering-equal-raw-different: fixture versions must be byte-different"
    )
    assert_catalog_matches_observed_decision({
      name = "observe-issue-entry-ordering-equal-raw-different",
      current_state = "thinking",
      current_version = V_ORDERING_EQUAL_CURRENT,
      incoming_version = V_ORDERING_EQUAL_INCOMING,
    })
  end,

  test_observe_issue_entry_malformed_payload_fails_closed_before_cas = function()
    assert_malformed_fails_closed_before_cas()
  end,

  test_r9_observe_issue_entry_old_equals_new_normalized_trace = function()
    assert_observe_issue_entry_trace_equality()
  end,
}
