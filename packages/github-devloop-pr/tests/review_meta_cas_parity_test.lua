-- Non-circularity contract: production truth comes from the real review_meta
-- department's owner decision and the result-marker check admission boundary.
-- Frozen OLD payload truth remains the committed R9 corpus, and direct legacy CAS
-- use is rejected after the production swap.

local catalog = require("devloop.restart_cas_catalog")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local devloop_logging = require("devloop.logging")
local m_builders = require("devloop.markers.builders")
local m_facts = require("devloop.markers.facts")
local devloop_state = require("devloop.state")
local dispatch_live_run = require("devloop.dispatch_live_run")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)
local review_meta_department = require("departments.review_meta.main")
local restart_authority = require("core.restart_authority")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")

local OWNER = "github-devloop-pr"
local POLICY_ID = "cas.legacy_review_meta_v1"
local VARIANT = "predecision_eligibility"
local V_OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local V_ORDERING_EQUAL_CURRENT = V_EQUAL .. "/loop/01"
local V_ORDERING_EQUAL_INCOMING = V_EQUAL .. "/loop/1"
local REVIEW_META_CORPUS_PATH = "migration/intent_bounded_replay/corpus/pr-review-meta.json"
local REVIEW_META_NEW_TRACE_PATH = ".fkst/run/r9-pr-review-meta-new-trace.json"

local function mock_meta_codex(stdout)
  t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
    stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", { stdout = stdout, stderr = "", exit_code = 0 })
end

local function observe_department(run)
  local probes = {}
  local decisions = {}
  local marker_checks = {}
  local effect_builders = { comment = {}, label = {} }
  local original_build_comment = core.build_review_meta_comment_request
  local original_build_label = core.build_review_meta_label_request
  local original_cyclic = devloop_state.cyclic_transition_status
  local original_decide_transition = restart_effects.decide_transition
  local original_mint_grant = restart_effects.mint_grant
  local original_log_cas = devloop_logging.log_cas_decision
  local original_has_review_meta_marker = m_facts.has_review_meta_marker
  local owner_decisions = {}
  local grant_mints = {}
  -- A fresh fixture has no live codex run; force the liveness dedup to its true
  -- no-live-run value so the post-admission effect path is deterministic. The
  -- live-run registry is keyed by (role, proposal_id, dedup_key) and is shared
  -- across cases, so leaving it real makes emit-vs-defer depend on test ordering
  -- (a cross-case lease artifact), not on the CAS admission this harness verifies.
  local original_dispatch_live_run_dedup = dispatch_live_run.dispatch_live_run_dedup
  dispatch_live_run.dispatch_live_run_dedup = function()
    return false
  end

  devloop_state.cyclic_transition_status = function()
    error("PR review-meta production used retired direct CAS", 0)
  end
  restart_effects.decide_transition = function(snapshot, intent)
    local decision = original_decide_transition(snapshot, intent)
    table.insert(owner_decisions, {
      snapshot = snapshot,
      intent = intent,
      decision = decision,
    })
    if #probes == 0 then
      table.insert(probes, {
        current = snapshot.current,
        from_states = { "review-meta" },
        to_state = "fixing",
        incoming_version = intent.incoming_version,
        target_version = intent.target_version,
        outcome = original_cyclic(
          snapshot.current,
          { "review-meta" },
          "fixing",
          intent.incoming_version,
          intent.target_version
        ),
      })
    end
    return decision
  end
  restart_effects.mint_grant = function(snapshot, decision, sink_id)
    table.insert(grant_mints, {
      snapshot = snapshot,
      decision = decision,
      sink_id = sink_id,
    })
    return original_mint_grant(snapshot, decision, sink_id)
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
  m_facts.has_review_meta_marker = function(comments, proposal_id, dedup_key)
    table.insert(marker_checks, {
      comments = comments,
      proposal_id = proposal_id,
      dedup_key = dedup_key,
    })
    return original_has_review_meta_marker(comments, proposal_id, dedup_key)
  end
  core.build_review_meta_comment_request = function(repo, issue_number, review_meta, action, reason, version, blocking_gap)
    table.insert(effect_builders.comment, {
      repo = repo,
      issue_number = issue_number,
      review_meta = review_meta,
      action = action,
      reason = reason,
      version = version,
      blocking_gap = blocking_gap,
    })
    return original_build_comment(repo, issue_number, review_meta, action, reason, version, blocking_gap)
  end
  core.build_review_meta_label_request = function(repo, issue_number, review_meta, action, version)
    table.insert(effect_builders.label, {
      repo = repo,
      issue_number = issue_number,
      review_meta = review_meta,
      action = action,
      version = version,
    })
    return original_build_label(repo, issue_number, review_meta, action, version)
  end

  local ok, result = pcall(run)
  core.build_review_meta_label_request = original_build_label
  core.build_review_meta_comment_request = original_build_comment
  dispatch_live_run.dispatch_live_run_dedup = original_dispatch_live_run_dedup
  m_facts.has_review_meta_marker = original_has_review_meta_marker
  devloop_logging.log_cas_decision = original_log_cas
  restart_effects.mint_grant = original_mint_grant
  restart_effects.decide_transition = original_decide_transition
  devloop_state.cyclic_transition_status = original_cyclic
  if not ok then
    error(result, 0)
  end
  return result, probes, decisions, marker_checks, effect_builders, owner_decisions, grant_mints
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

local function current_fact(state, version)
  return { state = state, version = version }
end

local function evidence_from_fixture(fixture)
  return {
    current = current_fact(fixture.current_state, fixture.current_version),
    variant = VARIANT,
    incoming_version = fixture.incoming_version,
    overlay_version = fixture.incoming_version,
  }
end

local function emitted_state(result)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == "github-proxy.github_pr_comment_request" then
      return tostring(raised.payload and raised.payload.body or ""):match('state="([^"]+)"')
    end
  end
  return nil
end

local function observed_admission(probe, decision, marker_check_reached)
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
    error("review-meta admission probe returned an unknown outcome: " .. tostring(probe.outcome))
  end

  local legacy_reason = tostring(decision and decision.reason or "")
  if legacy_reason:find("no longer review%-meta") ~= nil then
    return { status = "stale", reason_code = "from-state-mismatch" }
  end
  if legacy_reason:find("event version does not match canonical issue marker", 1, true) ~= nil then
    return { status = "stale", reason_code = "version-mismatch" }
  end
  if marker_check_reached then
    return { status = "apply", reason_code = "apply" }
  end
  error("review-meta admission apply did not reach a classified guard")
end

local function post_admission_disposition(result, decision, marker_check_reached)
  local outcome = tostring(decision and decision.outcome or "")
  local reason = tostring(decision and decision.reason or "")
  if outcome:find("skip%-stale", 1) ~= nil
    or reason:find("no longer review%-meta") ~= nil
    or reason:find("event version does not match canonical issue marker", 1, true) ~= nil then
    return "not-admitted"
  end
  if not marker_check_reached then
    return "not-admitted"
  end
  local state = emitted_state(result)
  if state ~= nil then
    return "effect-emitted(" .. state .. ")"
  end
  if outcome:find("review%-meta marker already visible") ~= nil then
    return "effect-idempotent"
  end
  if outcome:find("live%-exec%-ref") ~= nil then
    return "liveness-deferred"
  end
  return "codex-defer"
end

local function run_real_department(event)
  local raises = {}
  local original_raise = raise
  raise = function(queue, payload)
    table.insert(raises, { queue = queue, payload = payload })
  end
  local ok, failure = pcall(review_meta_department.pipeline, {
    queue = "devloop_review_meta",
    payload = event,
  })
  raise = original_raise
  return {
    exit_code = ok and 0 or 1,
    error = ok and nil or tostring(failure),
    raises = raises,
  }
end

local function assert_catalog_matches_observed_decision(fixture)
  local event = h.review_meta_event({ version = fixture.incoming_version })
  local comments = {}
  if fixture.current_state ~= nil then
    table.insert(comments, core.state_marker(event.proposal_id, fixture.current_state, fixture.current_version))
  end
  if fixture.result_marker_visible then
    table.insert(comments, m_builders.review_meta_marker(
      event.proposal_id,
      event.dedup_key,
      "block",
      core.next_review_meta_action_version(event.version)
    ))
  end
  h.mock_issue_review_meta({}, comments)
  if fixture.codex_stdout ~= nil then
    mock_meta_codex(fixture.codex_stdout)
    h.mock_context_bundle(event)
  end
  h.mock_default_issue_claim()
  h.mock_pr_origin(nil, "devloop-owner-repo-42-01HY", "def456", "OPEN", "dev")

  local result, probes, decisions, marker_checks, effect_builders, owner_decisions, grant_mints = observe_department(function()
    return run_real_department(event)
  end)

  t.eq(#probes, 1, fixture.name .. ": real department CAS probe count")
  local probe = probes[1]
  t.eq(probe.current.state, fixture.current_state, fixture.name .. ": probe current state")
  t.eq(probe.current.version, fixture.current_version, fixture.name .. ": probe current version")
  t.eq(probe.from_states[1], "review-meta", fixture.name .. ": probe source state")
  t.eq(#probe.from_states, 1, fixture.name .. ": probe source state count")
  t.eq(probe.to_state, "fixing", fixture.name .. ": legacy shared probe target")
  t.eq(probe.incoming_version, fixture.incoming_version, fixture.name .. ": probe incoming version")
  t.eq(probe.target_version, nil, fixture.name .. ": probe target version")

  local expected_owner_decisions = fixture.effect_state == "blocked" and 2 or 1
  t.eq(#owner_decisions, expected_owner_decisions, fixture.name .. ": owner decision count")
  t.eq(owner_decisions[1].intent.semantic_variant, "fix", fixture.name .. ": predecision gate variant")
  t.eq(owner_decisions[1].intent.target, "fixing", fixture.name .. ": predecision gate target")

  t.eq(#decisions, 1, fixture.name .. ": structured CAS decision count")
  local decision = decisions[1]
  t.eq(decision.dept, "review_meta", fixture.name .. ": CAS decision department")
  t.eq(decision.from_state, "review-meta", fixture.name .. ": logged source state")
  t.eq(decision.to_state, "fixing|blocked", fixture.name .. ": logged decision family")
  t.is_true(type(decision.outcome) == "string", fixture.name .. ": legacy log outcome captured")
  t.is_true(type(decision.reason) == "string", fixture.name .. ": legacy log reason captured")

  local marker_check_reached = #marker_checks > 0
  t.eq(#marker_checks, fixture.marker_check_reached == false and 0 or 1, fixture.name .. ": marker admission boundary reach")
  if marker_check_reached then
    t.eq(marker_checks[1].proposal_id, event.proposal_id, fixture.name .. ": marker boundary proposal")
    t.eq(marker_checks[1].dedup_key, event.dedup_key, fixture.name .. ": marker boundary dedup")
  end
  local observed = observed_admission(probe, decision, marker_check_reached)
  local actual = catalog.resolve(POLICY_ID, evidence_from_fixture(fixture), projection)
  t.eq(actual.status, observed.status, fixture.name .. ": admission status parity")
  t.eq(actual.reason_code, observed.reason_code, fixture.name .. ": admission reason parity")
  if fixture.probe_outcome ~= nil then
    t.eq(probe.outcome, fixture.probe_outcome, fixture.name .. ": literal probe outcome")
  end
  if fixture.admission_status ~= nil then
    t.eq(observed.status, fixture.admission_status, fixture.name .. ": observed admission status")
    t.eq(actual.status, fixture.admission_status, fixture.name .. ": catalog admission status")
  end
  if fixture.admission_reason_code ~= nil then
    t.eq(observed.reason_code, fixture.admission_reason_code, fixture.name .. ": observed admission reason")
    t.eq(actual.reason_code, fixture.admission_reason_code, fixture.name .. ": catalog admission reason")
  end
  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.name .. ": department exit code")

  local disposition = post_admission_disposition(result, decision, marker_check_reached)
  t.eq(disposition, fixture.post_admission_disposition or "not-admitted", fixture.name .. ": post-admission disposition")
  if fixture.legacy_log_outcome ~= nil then
    t.eq(decision.outcome, fixture.legacy_log_outcome, fixture.name .. ": legacy log outcome")
  end
  if fixture.legacy_log_reason ~= nil then
    t.eq(decision.reason, fixture.legacy_log_reason, fixture.name .. ": legacy log reason")
  end

  if fixture.effect_state ~= nil then
    t.eq(probe.outcome, "apply", fixture.name .. ": decision reached only after the shared probe applied")
    t.eq(emitted_state(result), fixture.effect_state, fixture.name .. ": emitted effect target")
    t.eq(#grant_mints, 1, fixture.name .. ": exactly one result grant minted")
    t.eq(grant_mints[1].sink_id, "comment:pr:review-meta-result", fixture.name .. ": result grant sink")
    local expected_variant = fixture.effect_state == "blocked" and "block" or "fix"
    t.eq(grant_mints[1].decision.edge_id,
      OWNER .. "/review-meta/autonomous/" .. expected_variant,
      fixture.name .. ": action-selected grant edge")
  else
    t.eq(emitted_state(result), nil, fixture.name .. ": non-apply case emitted no state effect")
    t.eq(#grant_mints, 0, fixture.name .. ": non-effect path minted no grant")
  end
  return {
    result = result,
    event = event,
    probe = probe,
    decision = decision,
    observed = observed,
    effect_builders = effect_builders,
    owner_decisions = owner_decisions,
    grant_mints = grant_mints,
  }
end

local TRACE_FIXTURES = {
  {
    fixture_id = "source-equal-block-apply",
    name = "r9-pr-review-meta-block-apply",
    semantic_variant = "block",
    target = "blocked",
    current_state = "review-meta",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    codex_stdout = h.action_label .. " block\n" .. h.reason_label .. " The review cannot be repaired safely.",
    effect_state = "blocked",
    marker_check_reached = true,
    post_admission_disposition = "effect-emitted(blocked)",
  },
  {
    fixture_id = "source-equal-fix-apply",
    name = "r9-pr-review-meta-fix-apply",
    semantic_variant = "fix",
    target = "fixing",
    current_state = "review-meta",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    codex_stdout = h.action_label .. " fix\n" .. h.reason_label .. " Run another fix pass.\nBlocking gap: missing CAS parity guard",
    effect_state = "fixing",
    marker_check_reached = true,
    post_admission_disposition = "effect-emitted(fixing)",
  },
  {
    fixture_id = "source-older-stale",
    name = "r9-pr-review-meta-stale",
    semantic_variant = "fix",
    target = "fixing",
    current_state = "review-meta",
    current_version = V_EQUAL,
    incoming_version = V_OLDER,
    legacy_log_outcome = "skip-stale(incoming version < current marker version)",
    legacy_log_reason = "current marker is no longer review-meta",
  },
  {
    fixture_id = "target-idempotent",
    name = "r9-pr-review-meta-idempotent",
    semantic_variant = "fix",
    target = "fixing",
    current_state = "fixing",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    result_marker_visible = true,
    marker_check_reached = true,
    post_admission_disposition = "effect-idempotent",
  },
}

local function trace_artifact(corpus_hash, fixtures)
  return observation_support.admission_trace_artifact(
    "restart-pr-review-meta-trace.v1", OWNER, "pr-review-meta", corpus_hash, fixtures
  )
end

local function new_trace_fixture(fixture, production)
  local snapshot = restart_effects.seal_snapshot({
    owner = OWNER,
    entity = { kind = "pr", repo = "owner/repo", number = 7 },
    proposal_id = production.event.proposal_id,
    current = { state = fixture.current_state, version = fixture.current_version },
    snapshot_fingerprint = "r9-pr-review-meta:" .. fixture.fixture_id,
    lock_epoch = "r9-pr-review-meta:lock",
    generation = "r9-pr-review-meta:generation",
  })
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = fixture.semantic_variant,
    target = fixture.target,
    incoming_version = fixture.incoming_version,
    overlay_version = fixture.incoming_version,
  })
  local writes = observation_support.json_array()
  if decided.status == "apply" then
    local grant = restart_effects.mint_grant(snapshot, decided, "comment:pr:review-meta-result")
    t.is_true(grant ~= nil, fixture.fixture_id .. ": NEW grant minted")
    local comment = production.effect_builders.comment[1]
    local label = production.effect_builders.label[1]
    t.is_true(comment ~= nil, fixture.fixture_id .. ": OLD comment builder observed")
    t.is_true(label ~= nil, fixture.fixture_id .. ": OLD label builder observed")
    local facade = restart_effect_facade.make({
      family = "pr-review-meta",
      verify_grant = restart_effects.verify_grant,
      sink_inventory = require("core.restart.sink_inventory"),
    })
    local args = {
      core = core,
      repo = comment.repo,
      issue_number = comment.issue_number,
      review_meta = comment.review_meta,
      action = comment.action,
      reason = comment.reason,
      version = comment.version,
      blocking_gap = comment.blocking_gap,
    }
    t.eq(label.repo, args.repo, fixture.fixture_id .. ": OLD builders share repo")
    t.eq(label.issue_number, args.issue_number, fixture.fixture_id .. ": OLD builders share issue")
    t.eq(label.review_meta, args.review_meta, fixture.fixture_id .. ": OLD builders share payload")
    t.eq(label.action, args.action, fixture.fixture_id .. ": OLD builders share action")
    t.eq(label.version, args.version, fixture.fixture_id .. ": OLD builders share version")
    for ordinal, effect_id in ipairs(decided.granted_effect_ids) do
      local emitted = facade.emit(grant, effect_id, snapshot, args)
      t.is_true(emitted ~= nil, fixture.fixture_id .. ": NEW facade emitted " .. effect_id)
      table.insert(writes, observation_support.admission_trace_write(ordinal, effect_id, emitted))
    end
  end
  return decided, writes
end

local function assert_review_meta_trace_equality()
  local corpus = json.decode(file.read(REVIEW_META_CORPUS_PATH))
  local old_fixtures = observation_support.json_array()
  local new_fixtures = observation_support.json_array()
  for _, fixture in ipairs(TRACE_FIXTURES) do
    local production = assert_catalog_matches_observed_decision(fixture)
    local decided, new_writes = new_trace_fixture(fixture, production)
    local old_writes = production.observed.status == "apply"
      and observation_support.admission_trace_writes(
        production.result.raises,
        "R9 PR review-meta trace"
      )
      or observation_support.json_array()
    local edge_id = OWNER .. "/review-meta/autonomous/" .. fixture.semantic_variant
    table.insert(old_fixtures, observation_support.admission_trace_fixture(
      fixture,
      edge_id,
      production.observed.status,
      production.observed.reason_code,
      devloop_state.cas_outcome(
        production.probe.current,
        production.probe.outcome,
        fixture.incoming_version
      ),
      decided.effect_entitlement_id,
      decided.granted_effect_ids,
      old_writes
    ))
    table.insert(new_fixtures, observation_support.admission_trace_fixture(
      fixture,
      edge_id,
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
    "R9 PR review-meta OLD and NEW semantic trace")
  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 PR review-meta trace could not create its artifact directory", 0)
  end
  file.write(REVIEW_META_NEW_TRACE_PATH, canonical_json(new_trace) .. "\n")
  t.eq(canonical_json(old_trace), canonical_json(corpus),
    "R9 PR review-meta OLD observation corpus")
  t.eq(canonical_json(new_trace), canonical_json(corpus),
    "R9 PR review-meta NEW semantic trace")
end

local function assert_bidirectional(actual, expected, field, context)
  t.eq(actual[field], expected[field], context .. ": shadow-to-production " .. field)
  t.eq(expected[field], actual[field], context .. ": production-to-shadow " .. field)
end

local function assert_shadow_case(fixture, semantic_variant, target)
  local production = assert_catalog_matches_observed_decision(fixture)
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
  t.eq(intent.source_boundary, nil, fixture.name .. ": nil boundary is omitted from shadow intent")

  local shadow, evidence = observe_shadow(function()
    return restart_authority.decide_transition(sealed_snapshot, intent)
  end)
  local observed = {
    status = production.observed.status,
    reason_code = production.observed.reason_code,
    cas_outcome = devloop_state.cas_outcome(
      production.probe.current,
      production.probe.outcome,
      production.probe.incoming_version
    ),
  }

  assert_bidirectional(shadow, observed, "status", fixture.name)
  assert_bidirectional(shadow, observed, "reason_code", fixture.name)
  assert_bidirectional(shadow, observed, "cas_outcome", fixture.name)
  t.eq(
    shadow.edge_id,
    "github-devloop-pr/review-meta/autonomous/" .. semantic_variant,
    fixture.name .. ": selected edge"
  )
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
  t.eq(evidence.current.state, fixture.current_state, fixture.name .. ": evidence current state")
  t.eq(evidence.current.version, fixture.current_version or "", fixture.name .. ": evidence raw current version")
  t.eq(evidence.variant, VARIANT, fixture.name .. ": evidence variant")
  t.eq(evidence.incoming_version, fixture.incoming_version, fixture.name .. ": evidence incoming version")
  t.eq(evidence.target_version, nil, fixture.name .. ": evidence target version")
  t.eq(evidence.overlay_version, fixture.incoming_version, fixture.name .. ": evidence overlay version")
end

local function assert_rejected_before_cas(name, payload, expected_reason_code)
  local _, probes = observe_department(function()
    return run_real_department(payload)
  end)
  t.eq(#probes, 0, name .. ": invalid production input must not reach CAS")
  local evidence = {
    current = current_fact("review-meta", V_EQUAL),
    variant = VARIANT,
    incoming_version = payload.version,
    overlay_version = payload.version,
  }
  t.eq(evidence.incoming_version, payload.version, name .. ": catalog incoming version comes from rejected payload")
  t.eq(evidence.overlay_version, payload.version, name .. ": catalog overlay version comes from rejected payload")
  local resolved = catalog.resolve(POLICY_ID, evidence, projection)
  t.eq(resolved.status, "illegal", name .. ": catalog status")
  t.eq(resolved.reason_code, expected_reason_code, name .. ": catalog reason")
  t.eq(resolved.cas_outcome, "illegal(" .. expected_reason_code .. ")", name .. ": catalog fails closed")
end

local function assert_local_source_marker_pending(name, current_state, current_version, incoming_version, catalog_pending)
  local event = h.review_meta_event({ version = incoming_version or V_EQUAL })
  local comments = {}
  if current_state ~= nil then
    table.insert(comments, core.state_marker(event.proposal_id, current_state, current_version or V_EQUAL))
  end
  h.mock_issue_review_meta({}, comments)
  h.mock_default_issue_claim()
  h.mock_pr_origin(nil, "devloop-owner-repo-42-01HY", "def456", "OPEN", "dev")

  local result, probes, decisions, marker_checks = observe_department(function()
    return run_real_department(event)
  end)

  t.eq(result.exit_code, 1, name .. ": absent source marker must retry")
  t.eq(#probes, 0, name .. ": local source-marker guard must run before cyclic CAS")
  t.eq(#marker_checks, 1, name .. ": exact decision marker must be checked first")
  t.eq(#decisions, 1, name .. ": retry decision count")
  t.eq(decisions[1].outcome, "retry-pending(from-state marker not yet visible)", name .. ": retry outcome")
  t.is_true(tostring(result.error or ""):find("review%-meta state marker not yet visible; retrying") ~= nil, name .. ": retry error")
  if catalog_pending then
    local resolved = catalog.resolve(POLICY_ID, {
      current = current_state ~= nil and current_fact(current_state, current_version or V_EQUAL) or nil,
      variant = VARIANT,
      incoming_version = incoming_version or V_EQUAL,
      overlay_version = incoming_version or V_EQUAL,
    }, projection)
    t.eq(resolved.status, "pending", name .. ": catalog pending parity")
  end
end

return {
  test_shadow_review_meta_predecision_matches_reachable_cas_outcomes = function()
    local fixtures = {
      {
        fixture = {
          name = "shadow-review-meta-fix-apply",
          current_state = "review-meta",
          current_version = V_EQUAL,
          incoming_version = V_EQUAL,
          codex_stdout = h.action_label .. " fix\n" .. h.reason_label .. " Run another fix pass.\nBlocking gap: missing CAS parity guard",
          effect_state = "fixing",
          marker_check_reached = true,
          post_admission_disposition = "effect-emitted(fixing)",
        },
        semantic_variant = "fix",
        target = "fixing",
      },
      {
        fixture = {
          name = "shadow-review-meta-block-apply",
          current_state = "review-meta",
          current_version = V_EQUAL,
          incoming_version = V_EQUAL,
          codex_stdout = h.action_label .. " block\n" .. h.reason_label .. " The review cannot be repaired safely.",
          effect_state = "blocked",
          marker_check_reached = true,
          post_admission_disposition = "effect-emitted(blocked)",
        },
        semantic_variant = "block",
        target = "blocked",
      },
      {
        fixture = {
          name = "shadow-review-meta-fix-idempotent",
          current_state = "fixing",
          current_version = V_EQUAL,
          incoming_version = V_EQUAL,
          result_marker_visible = true,
          marker_check_reached = true,
          post_admission_disposition = "effect-idempotent",
        },
        semantic_variant = "fix",
        target = "fixing",
      },
    }
    for _, case in ipairs(fixtures) do
      assert_shadow_case(case.fixture, case.semantic_variant, case.target)
    end
  end,
  test_review_meta_source_older_is_stale = function()
    assert_catalog_matches_observed_decision({
      name = "review-meta-source-older",
      current_state = "review-meta",
      current_version = V_EQUAL,
      incoming_version = V_OLDER,
    })
  end,

  test_review_meta_source_equal_fix_applies_to_fixing = function()
    assert_catalog_matches_observed_decision({
      name = "review-meta-source-equal-fix",
      current_state = "review-meta",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      codex_stdout = h.action_label .. " fix\n" .. h.reason_label .. " Run another fix pass.\nBlocking gap: missing CAS parity guard",
      effect_state = "fixing",
      marker_check_reached = true,
      post_admission_disposition = "effect-emitted(fixing)",
    })
  end,

  test_review_meta_source_equal_block_applies_to_blocked = function()
    assert_catalog_matches_observed_decision({
      name = "review-meta-source-equal-block",
      current_state = "review-meta",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      codex_stdout = h.action_label .. " block\n" .. h.reason_label .. " The review cannot be repaired safely.",
      effect_state = "blocked",
      marker_check_reached = true,
      post_admission_disposition = "effect-emitted(blocked)",
    })
  end,

  test_review_meta_ordering_equal_raw_different_is_stale_version_mismatch = function()
    t.is_true(
      V_ORDERING_EQUAL_CURRENT ~= V_ORDERING_EQUAL_INCOMING,
      "review-meta-ordering-equal-raw-different: fixture versions must be byte-different"
    )
    assert_catalog_matches_observed_decision({
      name = "review-meta-ordering-equal-raw-different",
      current_state = "review-meta",
      current_version = V_ORDERING_EQUAL_CURRENT,
      incoming_version = V_ORDERING_EQUAL_INCOMING,
      probe_outcome = "apply",
      admission_status = "stale",
      admission_reason_code = "version-mismatch",
      legacy_log_outcome = "skip-stale(version-mismatch)",
      legacy_log_reason = "review-meta event version does not match canonical issue marker",
    })
  end,

  test_review_meta_source_equal_visible_result_marker_is_admitted_then_idempotent = function()
    assert_catalog_matches_observed_decision({
      name = "review-meta-source-equal-result-visible",
      current_state = "review-meta",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      result_marker_visible = true,
      marker_check_reached = true,
      post_admission_disposition = "effect-idempotent",
    })
  end,

  test_review_meta_source_newer_is_pending = function()
    assert_local_source_marker_pending("review-meta-source-newer", "review-meta", V_EQUAL, V_NEWER, true)
  end,

  test_review_meta_missing_current_marker_is_pending = function()
    assert_local_source_marker_pending("review-meta-current-missing", nil, nil, V_EQUAL, true)
  end,

  test_review_meta_target_state_is_idempotent = function()
    assert_catalog_matches_observed_decision({
      name = "review-meta-target-idempotent",
      current_state = "fixing",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      result_marker_visible = true,
      marker_check_reached = true,
      post_admission_disposition = "effect-idempotent",
    })
  end,

  test_review_meta_same_version_fixing_without_source_or_decision_marker_is_pending = function()
    assert_local_source_marker_pending("review-meta-fixing-predecessor-pending", "fixing")
  end,

  test_review_meta_unrelated_state_is_stale = function()
    assert_catalog_matches_observed_decision({
      name = "review-meta-unrelated-stale",
      current_state = "blocked",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      legacy_log_outcome = "skip-advanced-or-diverged",
      legacy_log_reason = "current marker is no longer review-meta",
    })
  end,

  test_review_meta_predecessor_with_older_event_is_stale = function()
    assert_catalog_matches_observed_decision({
      name = "review-meta-predecessor-older",
      current_state = "reviewing",
      current_version = V_EQUAL,
      incoming_version = V_OLDER,
    })
  end,

  test_review_meta_predecessor_with_equal_event_matches_production_admission = function()
    assert_local_source_marker_pending("review-meta-predecessor-equal", "reviewing")
  end,

  test_r9_pr_review_meta_old_equals_new_normalized_trace = function()
    assert_review_meta_trace_equality()
  end,

  test_review_meta_malformed_evidence_and_payload_fail_closed_before_cas = function()
    local payload = h.review_meta_event()
    payload.version = 42
    assert_rejected_before_cas("review-meta-malformed-version", payload, "invalid-evidence")
  end,
}
