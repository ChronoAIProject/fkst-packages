-- Non-circularity contract: production truth comes from the real review_loop
-- department's owner-decider and grant-facade path. Frozen OLD truth is the
-- former local reviewing_segment_transition_status body copied byte-for-byte
-- before the swap; the frozen observation corpus remains unchanged.

local catalog = require("devloop.restart_cas_catalog")
local restart_authority = require("core.restart_authority")
local restart_effects = require("core.restart_effects")
local restart_effect_facade = require("core.restart_effect_facade")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local convergence_shared = require("devloop.convergence.shared")
local conv_rounds = require("devloop.convergence.rounds")
local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local m_builders = require("devloop.markers.builders")
local requests_review = require("devloop.requests.review")
local transition_version = require("contract.transition_version")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)
local review_loop_department = require("departments.review_loop.main")

local POLICY_ID = "cas.legacy_review_loop_safe_v1"
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local REPO = "owner/repo"
local PR_NUMBER = 7
local BRANCH = "devloop-owner-repo-42-01HY"
local BASE_BRANCH = "dev"
local HEAD_SHA = "def456"
local SOURCE_BOUNDARY = "consensus.consensus_converge"
local SEMANTIC_VARIANT = "review_convergence_round"
local OWNER = "github-devloop-pr"
local TRACE_EDGE_ID = OWNER .. "/reviewing/entry/review_convergence_round"
local REVIEW_LOOP_CORPUS_PATH = "migration/intent_bounded_replay/corpus/pr-review-loop.json"
local REVIEW_LOOP_NEW_TRACE_PATH = ".fkst/run/r9-pr-review-loop-new-trace.json"
local V_OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"

local V_LONG = V_EQUAL
for _ = 1, 6 do
  V_LONG = core.next_fix_version(V_LONG)
end

local function observe_department(run)
  local probes = {}
  local decisions = {}
  local boundary_calls = {}
  local comment_builders = {}
  local parsed_review_versions = {}
  local owner_decisions = {}
  local grant_mints = {}
  local facade_emissions = {}
  local original_parse_pr_review_proposal_id = devloop_base.parse_pr_review_proposal_id
  local original_current_entity_state = entity_lib.current_entity_state
  local original_log_cas = devloop_logging.log_cas_decision
  local original_has_review_converge_round_marker = conv_rounds.has_review_converge_round_marker
  local original_build_review_converge_round_comment_request =
    requests_review.build_review_converge_round_comment_request
  local original_decide_transition = restart_effects.decide_transition
  local original_mint_grant = restart_effects.mint_grant
  local original_facade_make = restart_effect_facade.make

  -- Observe the production snapshot and resolve evidence at their adjacent
  -- providers: parse_pr_review_proposal_id supplies review_version, then
  -- current_entity_state supplies the comments and current state immediately
  -- before the owner snapshot is sealed.
  -- INVARIANT (keep true or this pairing drifts): the probe's parse is the LAST
  -- parse before its current_entity_state -- validation parses the proposal id
  -- earlier, so parsed_review_versions[#...] at the current_entity_state call is
  -- the probe's review_version. If a future edit inserts another parse between the
  -- probe's parse and its current_entity_state, capture the probe's parse by
  -- proposal identity instead of taking the latest.
  devloop_base.parse_pr_review_proposal_id = function(...)
    local parsed = { original_parse_pr_review_proposal_id(...) }
    table.insert(parsed_review_versions, parsed[3])
    return table.unpack(parsed)
  end
  entity_lib.current_entity_state = function(...)
    local args = { ... }
    local current = original_current_entity_state(...)
    table.insert(probes, {
      comments = args[1],
      proposal_id = args[2],
      current = current,
      review_version = parsed_review_versions[#parsed_review_versions],
    })
    return current
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
      probe_count = #probes,
    })
    return original_log_cas(dept, proposal_id, current, from_state, to_state, outcome, reason)
  end
  conv_rounds.has_review_converge_round_marker = function(...)
    local args = { ... }
    local visible = original_has_review_converge_round_marker(...)
    table.insert(boundary_calls, {
      review_proposal_id = args[3],
      issue_proposal_id = args[4],
      issue_version = args[5],
      head_sha = args[6],
      round = args[8],
      visible = visible,
      probe_count = #probes,
    })
    return visible
  end

  requests_review.build_review_converge_round_comment_request = function(...)
    local args = { ... }
    local request = original_build_review_converge_round_comment_request(...)
    table.insert(comment_builders, {
      core = args[1],
      repo = args[2],
      issue_number = args[3],
      unresolved = args[4],
      issue_proposal_id = args[5],
      round = args[6],
      marker_body = args[7],
      source_ref = args[8],
      request = request,
    })
    return request
  end
  restart_effects.decide_transition = function(snapshot, intent)
    local decision = original_decide_transition(snapshot, intent)
    table.insert(owner_decisions, {
      snapshot = snapshot,
      intent = intent,
      decision = decision,
    })
    return decision
  end
  restart_effects.mint_grant = function(snapshot, decision, sink_id)
    local grant = original_mint_grant(snapshot, decision, sink_id)
    table.insert(grant_mints, {
      snapshot = snapshot,
      decision = decision,
      sink_id = sink_id,
      grant = grant,
    })
    return grant
  end
  restart_effect_facade.make = function(config)
    local facade = original_facade_make(config)
    local original_emit = facade.emit
    facade.emit = function(grant, effect_id, snapshot, args)
      local payload, rejection = original_emit(grant, effect_id, snapshot, args)
      table.insert(facade_emissions, {
        effect_id = effect_id,
        snapshot = snapshot,
        args = args,
        payload = payload,
        rejection = rejection,
      })
      return payload, rejection
    end
    return facade
  end

  local ok, result = pcall(run)
  restart_effect_facade.make = original_facade_make
  restart_effects.mint_grant = original_mint_grant
  restart_effects.decide_transition = original_decide_transition
  requests_review.build_review_converge_round_comment_request =
    original_build_review_converge_round_comment_request
  conv_rounds.has_review_converge_round_marker = original_has_review_converge_round_marker
  devloop_logging.log_cas_decision = original_log_cas
  entity_lib.current_entity_state = original_current_entity_state
  devloop_base.parse_pr_review_proposal_id = original_parse_pr_review_proposal_id
  if not ok then
    error(result, 0)
  end
  if #probes == 1 and #owner_decisions == 1 then
    probes[1].outcome = owner_decisions[1].decision.status
  end
  return result, probes, decisions, boundary_calls, comment_builders,
    owner_decisions, grant_mints, facade_emissions
end

-- review_version is parse_pr_review_proposal_id's safe_version_segment form (truncated +
-- checksummed for long versions): it preserves version EQUALITY only, never ordering, so it
-- must NOT be fed to the ordering-based CAS. The PR head is already pinned to reviewed_head_sha
-- before the lock, so we only need: same reviewing version (segment equality) -> apply; issue
-- advanced past reviewing (stage_rank, which IS order-preserving) or reviewing at a different
-- version -> stale skip; not yet at reviewing -> pending retry.
local function frozen_old_reviewing_segment_transition_status(comments, proposal_id, review_version)
  local state = entity_lib.current_entity_state(comments, proposal_id)
  if state.state == "reviewing"
    and tostring(transition_version.safe_version_segment(state.version or "")) == tostring(review_version) then
    return state, "apply"
  end
  if state.state ~= nil and devloop_state.stage_rank(state.state) > devloop_state.stage_rank("reviewing") then
    return state, "stale"
  end
  if state.state == "reviewing" then
    -- reviewing but a different version segment (head already pinned): treat as version-mismatch stale, do not retry
    return state, "stale"
  end
  return state, "pending"  -- no marker yet, or a state earlier than reviewing -> reviewing marker not yet visible
end

local function frozen_old_admission(probe)
  local _, status = frozen_old_reviewing_segment_transition_status(
    probe.comments,
    probe.proposal_id,
    probe.review_version
  )
  if status == "apply" then
    return { status = "apply", reason_code = "apply", cas_outcome = "applied" }
  end
  if status == "stale" then
    return {
      status = "stale",
      reason_code = "reviewing-version",
      cas_outcome = "skip-stale(reviewing-version)",
    }
  end
  return {
    status = "pending",
    reason_code = "source-marker-not-visible",
    cas_outcome = devloop_state.cas_outcome(probe.current, "pending", probe.review_version),
  }
end

local function evidence_from_probe(probe)
  return {
    current = probe.current,
    review_version = probe.review_version,
  }
end

local function observe_shadow(run)
  local captured = nil
  local original_resolve = catalog.resolve
  catalog.resolve = function(policy_id, evidence, candidate_projection)
    captured = evidence
    return original_resolve(policy_id, evidence, candidate_projection)
  end
  local ok, result = pcall(run)
  catalog.resolve = original_resolve
  if not ok then
    error(result, 0)
  end
  return result, captured
end

local function assert_bidirectional(actual, expected, field, context)
  t.eq(actual[field], expected[field], context .. ": shadow-to-old " .. field)
  t.eq(expected[field], actual[field], context .. ": old-to-shadow " .. field)
end

local function review_event(version, overrides)
  local proposal_id = devloop_base.pr_review_proposal_id(REPO, PR_NUMBER, version, HEAD_SHA)
  local event = h.review_unresolved({
    proposal_id = proposal_id,
    dedup_key = "consensus:" .. proposal_id .. "/review",
  })
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function visible_round_marker(event, issue_version)
  return conv_rounds.review_converge_round_marker(
    core,
    event.proposal_id,
    PROPOSAL_ID,
    issue_version,
    HEAD_SHA,
    convergence_shared.source_ref_digest(event.source_ref),
    0,
    event.dedup_key,
    event.narrowed_question,
    event.angle_digests,
    event.findings_record,
    event.essence_stall == true
  )
end

local function run_real_department(event)
  local raises = {}
  local original_raise = raise
  raise = function(queue, payload)
    table.insert(raises, { queue = queue, payload = payload })
  end
  local ok, failure = pcall(review_loop_department.pipeline, {
    queue = "consensus.consensus_converge",
    payload = event,
  })
  raise = original_raise
  return {
    exit_code = ok and 0 or 1,
    error = ok and nil or tostring(failure),
    raises = raises,
  }
end

local function observed_admission(probe, boundary_reached)
  if probe == nil then
    return { status = "pre-cas", reason_code = "cas-probe-not-reached" }
  end
  local frozen = frozen_old_admission(probe)
  if frozen.status == "apply" and not boundary_reached then
    error("review-loop CAS apply did not reach the admission boundary")
  end
  return frozen
end

local function post_admission_disposition(result, decision, boundary_reached)
  if not boundary_reached then
    return "not-admitted"
  end
  if #(result.raises or {}) > 0 then
    return "effect-emitted"
  end
  if tostring(decision and decision.outcome or ""):find("round marker already visible", 1, true) ~= nil then
    return "effect-idempotent"
  end
  return "admitted-no-effect"
end

local function assert_review_loop_admission_case(fixture)
  local event = review_event(fixture.event_version, fixture.event_overrides)
  local comments = {
    m_builders.pr_origin_marker(PROPOSAL_ID, "42", BRANCH, fixture.event_version, BASE_BRANCH),
  }
  if fixture.current_state ~= nil then
    table.insert(comments, core.state_marker(PROPOSAL_ID, fixture.current_state, fixture.current_version))
  end
  if fixture.result_marker_visible then
    table.insert(comments, visible_round_marker(event, fixture.current_version))
  end

  h.mock_bot_env()
  h.mock_default_issue_claim(REPO, 42)
  h.mock_pr_origin_for({
    number = PR_NUMBER,
    comments = comments,
    head = BRANCH,
    head_sha = HEAD_SHA,
    state = "OPEN",
    base_branch = BASE_BRANCH,
  })

  local result, probes, decisions, boundary_calls, comment_builders,
    owner_decisions, grant_mints, facade_emissions = observe_department(function()
      return run_real_department(event)
    end)

  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.name .. ": department exit code")
  t.eq(#probes, 1, fixture.name .. ": real department CAS probe count")
  local probe = probes[1]
  t.eq(probe.current.state, fixture.current_state, fixture.name .. ": probe current state")
  t.eq(probe.current.version, fixture.current_version, fixture.name .. ": probe current version")
  t.is_true(type(probe.review_version) == "string", fixture.name .. ": probe review version")

  t.eq(#decisions, 1, fixture.name .. ": structured CAS decision count")
  local decision = decisions[1]
  t.eq(decision.dept, "review_loop", fixture.name .. ": CAS decision department")
  t.eq(decision.from_state, "reviewing", fixture.name .. ": logged source state")
  t.is_true(type(decision.outcome) == "string", fixture.name .. ": legacy log outcome captured")
  t.is_true(type(decision.reason) == "string", fixture.name .. ": legacy log reason captured")

  local boundary_reached = #boundary_calls > 0
  t.eq(boundary_reached, fixture.boundary_reached == true, fixture.name .. ": admission boundary reach")
  if boundary_reached then
    t.eq(#boundary_calls, 1, fixture.name .. ": admission boundary call count")
    t.eq(boundary_calls[1].probe_count, 1, fixture.name .. ": admission boundary follows probe")
    t.eq(boundary_calls[1].review_proposal_id, event.proposal_id, fixture.name .. ": boundary review proposal")
    t.eq(boundary_calls[1].issue_proposal_id, PROPOSAL_ID, fixture.name .. ": boundary issue proposal")
    t.eq(boundary_calls[1].issue_version, fixture.current_version, fixture.name .. ": boundary issue version")
    t.eq(boundary_calls[1].visible, fixture.result_marker_visible == true, fixture.name .. ": boundary marker visibility")
  end

  local observed = observed_admission(probe, boundary_reached)
  local resolved = catalog.resolve(POLICY_ID, evidence_from_probe(probe), projection)
  t.eq(#owner_decisions, 1, fixture.name .. ": production owner-decider call count")
  local production_call = owner_decisions[1]
  local production_decision = production_call.decision
  t.eq(production_call.intent.semantic_variant, SEMANTIC_VARIANT, fixture.name .. ": decider semantic variant")
  t.eq(production_call.intent.source_boundary, SOURCE_BOUNDARY, fixture.name .. ": decider source boundary")
  t.eq(production_call.intent.target, "reviewing", fixture.name .. ": decider target")
  t.eq(production_call.intent.review_version, probe.review_version, fixture.name .. ": resolve review version")
  t.eq(production_call.snapshot.current.state, probe.current.state, fixture.name .. ": sealed current state")
  t.eq(production_call.snapshot.current.version, probe.current.version, fixture.name .. ": sealed current version")
  assert_bidirectional(production_decision, observed, "status", fixture.name .. ": production-vs-frozen-old")
  assert_bidirectional(production_decision, observed, "reason_code", fixture.name .. ": production-vs-frozen-old")
  assert_bidirectional(production_decision, observed, "cas_outcome", fixture.name .. ": production-vs-frozen-old")
  t.eq(resolved.status, observed.status, fixture.name .. ": admission status parity")
  t.eq(resolved.reason_code, observed.reason_code, fixture.name .. ": admission reason parity")
  t.eq(probe.outcome, fixture.probe_outcome, fixture.name .. ": literal probe outcome")
  t.eq(observed.status, fixture.admission_status, fixture.name .. ": observed admission status")
  t.eq(resolved.status, fixture.admission_status, fixture.name .. ": catalog admission status")
  local expected_grants = fixture.post_admission_disposition == "effect-emitted" and 1 or 0
  t.eq(#grant_mints, expected_grants, fixture.name .. ": production grant count")
  t.eq(#facade_emissions, expected_grants, fixture.name .. ": production facade emission count")
  if expected_grants == 1 then
    t.eq(grant_mints[1].sink_id, "comment:pr:review-converge-round",
      fixture.name .. ": granted comment sink")
    t.eq(facade_emissions[1].effect_id, "github-proxy.github_pr_comment_request",
      fixture.name .. ": facade comment effect")
    t.eq(facade_emissions[1].rejection, nil, fixture.name .. ": facade accepted grant")
    t.eq(observation_support.canonical_json(facade_emissions[1].payload),
      observation_support.canonical_json(comment_builders[1].request),
      fixture.name .. ": facade payload is byte-exact OLD comment")
  end

  local sealed = restart_authority.seal_snapshot({
    owner = core.restart_package_name,
    proposal_id = event.proposal_id,
    current = {
      state = probe.current.state,
      version = probe.current.version,
    },
  })
  local shadow, shadow_evidence = observe_shadow(function()
    return restart_authority.decide_transition(sealed, {
      semantic_variant = SEMANTIC_VARIANT,
      source_boundary = SOURCE_BOUNDARY,
      target = "reviewing",
      evidence_refs = { "review-loop-cas-probe" },
      review_version = probe.review_version,
    })
  end)
  assert_bidirectional(shadow, resolved, "status", fixture.name)
  assert_bidirectional(shadow, resolved, "reason_code", fixture.name)
  assert_bidirectional(shadow, resolved, "cas_outcome", fixture.name)
  t.eq(
    shadow.edge_id,
    "github-devloop-pr/reviewing/entry/review_convergence_round",
    fixture.name .. ": selected edge"
  )
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
  t.eq(shadow_evidence.current.state, probe.current.state, fixture.name .. ": evidence current state")
  t.eq(shadow_evidence.current.version, probe.current.version, fixture.name .. ": evidence current version")
  t.eq(shadow_evidence.review_version, probe.review_version, fixture.name .. ": evidence review version")
  t.eq(shadow_evidence.reviewing_version, nil, fixture.name .. ": review-loop evidence has no activation version")
  t.eq(shadow_evidence.handoff, nil, fixture.name .. ": review-loop evidence has no activation handoff")
  t.eq(shadow_evidence.variant, nil, fixture.name .. ": resolve-based evidence has no variant")
  t.eq(shadow_evidence.incoming_version, nil, fixture.name .. ": resolve-based evidence has no incoming version")
  t.eq(shadow_evidence.target_version, nil, fixture.name .. ": resolve-based evidence has no target version")
  t.eq(shadow_evidence.overlay_version, nil, fixture.name .. ": resolve-based evidence has no overlay version")
  t.eq(
    post_admission_disposition(result, decision, boundary_reached),
    fixture.post_admission_disposition or "not-admitted",
    fixture.name .. ": post-admission disposition"
  )
  if fixture.legacy_log_outcome ~= nil then
    t.eq(decision.outcome, fixture.legacy_log_outcome, fixture.name .. ": legacy log outcome")
  end
  local expected_queues = fixture.expected_queues or {}
  t.eq(#result.raises, #expected_queues, fixture.name .. ": captured effect count")
  for index, expected_queue in ipairs(expected_queues) do
    t.eq(result.raises[index].queue, expected_queue,
      fixture.name .. ": captured effect queue " .. tostring(index))
  end
  return {
    result = result,
    event = event,
    probe = probe,
    decision = decision,
    observed = observed,
    comment_builders = comment_builders,
    production_decision = production_decision,
    grant_mints = grant_mints,
    facade_emissions = facade_emissions,
  }
end

local function assert_malformed_is_pre_cas_and_catalog_illegal()
  local malformed = review_event(V_EQUAL, { proposal_id = 42 })
  local result, probes, decisions, boundary_calls, _, owner_decisions, grant_mints,
    facade_emissions = observe_department(function()
      return run_real_department(malformed)
    end)

  t.eq(result.exit_code, 0, "review-loop-malformed: production rejects unsupported payload")
  t.eq(#probes, 0, "review-loop-malformed: production rejects before CAS")
  t.eq(#boundary_calls, 0, "review-loop-malformed: admission boundary is not reached")
  t.eq(#owner_decisions, 0, "review-loop-malformed: owner decider is not reached")
  t.eq(#grant_mints, 0, "review-loop-malformed: no grants")
  t.eq(#facade_emissions, 0, "review-loop-malformed: no facade emissions")
  t.eq(#result.raises, 0, "review-loop-malformed: no effects")
  t.eq(#decisions, 1, "review-loop-malformed: rejection decision count")
  t.eq(decisions[1].outcome, "skip-foreign(proposal_id)", "review-loop-malformed: rejection outcome")

  local resolved = catalog.resolve(POLICY_ID, {
    current = { state = "reviewing", version = V_EQUAL },
    review_version = malformed.proposal_id,
  }, projection)
  t.eq(resolved.status, "illegal", "review-loop-malformed: catalog status")
  t.eq(resolved.reason_code, "invalid-evidence", "review-loop-malformed: catalog reason")
  t.eq(resolved.cas_outcome, "illegal(invalid-evidence)", "review-loop-malformed: catalog fails closed")
end

-- The normalized trace stops at admission. Marker-visible selective idempotency
-- remains a separate post-admission assertion in the existing parity case below.
-- The terminal apply fixture also asserts its independent reconcile queue effect.
local TRACE_FIXTURES = {
  {
    fixture_id = "source-equal-apply",
    name = "r9-pr-review-loop-apply",
    current_state = "reviewing",
    current_version = V_EQUAL,
    event_version = V_EQUAL,
    event_overrides = {
      round = 0,
      narrowed_question = "Which reviewed-head evidence resolves the gap?",
      angle_digests = {
        { angle = "minimal", verdict = "abstain", digest = "external evidence required" },
      },
      essence_stall = true,
    },
    boundary_reached = true,
    probe_outcome = "apply",
    admission_status = "apply",
    post_admission_disposition = "effect-emitted",
    expected_queues = {
      "github-proxy.github_pr_comment_request",
      "devloop_review_reconcile",
    },
  },
  {
    fixture_id = "source-marker-missing-pending",
    name = "r9-pr-review-loop-pending",
    current_state = nil,
    current_version = nil,
    event_version = V_EQUAL,
    probe_outcome = "pending",
    admission_status = "pending",
    expected_exit_code = 1,
  },
  {
    fixture_id = "source-older-stale",
    name = "r9-pr-review-loop-stale",
    current_state = "reviewing",
    current_version = V_EQUAL,
    event_version = V_OLDER,
    probe_outcome = "stale",
    admission_status = "stale",
    legacy_log_outcome = "skip-stale(reviewing-version)",
  },
}

local function trace_artifact(corpus_hash, fixtures)
  return observation_support.admission_trace_artifact(
    "restart-pr-review-loop-trace.v1", OWNER, "pr-review-loop", corpus_hash, fixtures
  )
end

local function new_trace_fixture(fixture, production)
  local decided = production.production_decision
  local writes = observation_support.json_array()
  for ordinal, emitted in ipairs(production.facade_emissions) do
    table.insert(writes,
      observation_support.admission_trace_write(ordinal, emitted.effect_id, emitted.payload))
  end
  return decided, writes
end

local function admission_trace_writes(raises, granted_effect_ids)
  local admitted = {}
  for _, effect_id in ipairs(granted_effect_ids or {}) do
    admitted[effect_id] = true
  end
  local scoped = observation_support.json_array()
  for _, raised in ipairs(raises or {}) do
    if admitted[raised.queue] == true then
      table.insert(scoped, raised)
    end
  end
  return observation_support.admission_trace_writes(
    scoped,
    "R9 PR review-loop trace"
  )
end

local function assert_review_loop_trace_equality()
  local corpus = json.decode(file.read(REVIEW_LOOP_CORPUS_PATH))
  local old_fixtures = observation_support.json_array()
  local new_fixtures = observation_support.json_array()
  for _, fixture in ipairs(TRACE_FIXTURES) do
    local production = assert_review_loop_admission_case(fixture)
    local decided, new_writes = new_trace_fixture(fixture, production)
    local old_writes = production.observed.status == "apply"
      and admission_trace_writes(production.result.raises, decided.granted_effect_ids)
      or observation_support.json_array()
    table.insert(old_fixtures, observation_support.admission_trace_fixture(
      fixture,
      TRACE_EDGE_ID,
      production.observed.status,
      production.observed.reason_code,
      production.decision.outcome,
      decided.effect_entitlement_id,
      decided.granted_effect_ids,
      old_writes
    ))
    table.insert(new_fixtures, observation_support.admission_trace_fixture(
      fixture,
      TRACE_EDGE_ID,
      decided.status,
      decided.reason_code,
      decided.cas_outcome,
      decided.effect_entitlement_id,
      decided.granted_effect_ids,
      new_writes
    ))
  end

  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  local new_trace = trace_artifact(corpus.artifact_sha256, new_fixtures)
  local canonical_json = observation_support.canonical_json
  t.eq(canonical_json(old_trace), canonical_json(new_trace),
    "R9 PR review-loop OLD and NEW semantic trace")
  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 PR review-loop trace could not create its artifact directory", 0)
  end
  file.write(REVIEW_LOOP_NEW_TRACE_PATH, canonical_json(new_trace) .. "\n")
  t.eq(canonical_json(old_trace), canonical_json(corpus),
    "R9 PR review-loop OLD observation corpus")
  t.eq(canonical_json(new_trace), canonical_json(corpus),
    "R9 PR review-loop NEW semantic trace")
end

return {
  test_review_loop_source_and_target_equal_applies_before_effect_idempotency = function()
    assert_review_loop_admission_case({
      name = "review-loop-source-target-equal",
      current_state = "reviewing",
      current_version = V_EQUAL,
      event_version = V_EQUAL,
      result_marker_visible = true,
      boundary_reached = true,
      probe_outcome = "apply",
      admission_status = "apply",
      post_admission_disposition = "effect-idempotent",
      legacy_log_outcome = "skip-idempotent(review converge round marker already visible)",
    })
  end,

  test_review_loop_safe_equal_raw_different_applies = function()
    t.is_true(V_LONG ~= transition_version.safe_version_segment(V_LONG), "review-loop-safe-equal: raw fixture differs")
    assert_review_loop_admission_case({
      name = "review-loop-safe-equal",
      current_state = "reviewing",
      current_version = V_LONG,
      event_version = V_LONG,
      result_marker_visible = true,
      boundary_reached = true,
      probe_outcome = "apply",
      admission_status = "apply",
      post_admission_disposition = "effect-idempotent",
    })
  end,

  test_review_loop_older_review_version_is_stale = function()
    assert_review_loop_admission_case({
      name = "review-loop-older-stale",
      current_state = "reviewing",
      current_version = V_EQUAL,
      event_version = V_OLDER,
      probe_outcome = "stale",
      admission_status = "stale",
      legacy_log_outcome = "skip-stale(reviewing-version)",
    })
  end,

  test_review_loop_newer_review_waits_for_reviewing_source = function()
    assert_review_loop_admission_case({
      name = "review-loop-newer-pending",
      current_state = "pr-open",
      current_version = V_EQUAL,
      event_version = V_NEWER,
      probe_outcome = "pending",
      admission_status = "pending",
      expected_exit_code = 1,
    })
  end,

  test_review_loop_missing_source_marker_is_pending = function()
    assert_review_loop_admission_case({
      name = "review-loop-missing-pending",
      current_state = nil,
      current_version = nil,
      event_version = V_EQUAL,
      probe_outcome = "pending",
      admission_status = "pending",
      expected_exit_code = 1,
    })
  end,

  test_review_loop_unrelated_later_current_is_stale = function()
    assert_review_loop_admission_case({
      name = "review-loop-unrelated-stale",
      current_state = "fixing",
      current_version = V_EQUAL,
      event_version = V_EQUAL,
      probe_outcome = "stale",
      admission_status = "stale",
    })
  end,

  test_review_loop_same_state_safe_version_mismatch_is_stale = function()
    assert_review_loop_admission_case({
      name = "review-loop-safe-version-mismatch",
      current_state = "reviewing",
      current_version = V_EQUAL,
      event_version = V_NEWER,
      probe_outcome = "stale",
      admission_status = "stale",
    })
  end,

  test_review_loop_malformed_evidence_and_payload_fail_closed_before_cas = function()
    assert_malformed_is_pre_cas_and_catalog_illegal()
  end,

  test_r9_pr_review_loop_old_equals_new_equals_corpus = function()
    assert_review_loop_trace_equality()
  end,
}
