-- Non-circularity contract: production truth comes from the real review_pr
-- department's owner-decider admission. Frozen OLD truth is the former local
-- reviewing_transition_status body copied byte-for-byte before the swap, plus
-- the observed direct-ID handoff result. Production must not mint a grant for
-- the separately declared consensus.proposal published intent.

local catalog = require("devloop.restart_cas_catalog")
local restart_authority = require("core.restart_authority")
local restart_effects = require("core.restart_effects")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local entity_lib = require("devloop.entity")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local m_builders = require("devloop.markers.builders")
local payloads_predicates = require("devloop.payloads.predicates")
local pr_safety = require("devloop.pr_safety")
local transition_version = require("contract.transition_version")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)
local review_pr_department = require("departments.review_pr.main")

local POLICY_ID = "cas.legacy_review_activation_handoff_v1"
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local BRANCH = "devloop-owner-repo-42-01HY"
local BASE_BRANCH = "dev"
local HEAD_SHA = "def456"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_DIFFERENT = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local V_SAFE_EQUAL_CURRENT = V_EQUAL .. "/loop/01"
local V_SAFE_EQUAL_EVENT = V_EQUAL .. "/loop/1"
local HANDOFF_COMMENT_ID = "IC_review_activation_handoff"
local SOURCE_BOUNDARY = "github-devloop-pr.devloop_reviewing"
local SEMANTIC_VARIANT = "review_receiver"

local function frozen_old_reviewing_transition_status(state, reviewing_version)
  if state == nil or state.version == nil then
    return "pending"
  end

  local state_base = transition_version.strip_suffixes(state.version)
  local reviewing_base = transition_version.strip_suffixes(reviewing_version)
  if state.state == "reviewing" then
    if tostring(state_base) == tostring(reviewing_base) then
      return "apply"
    end
    return "version-mismatch"
  end

  local canonical_order = devloop_state.compare_state_marker_order({
    state = state.state,
    version = state_base,
  }, "reviewing", reviewing_base)
  if canonical_order < 0 then
    return "pending"
  end
  return "stale"
end

local function observe_department(reviewing_version, run)
  local probes = {}
  local decisions = {}
  local handoff_checks = {}
  local boundary_calls = {}
  local sequence = 0
  local original_current_entity_state = entity_lib.current_entity_state
  local original_log_cas = devloop_logging.log_cas_decision
  local original_verified_hand_off_state = payloads_predicates.verified_hand_off_state
  local original_is_safe_head_sha = pr_safety.is_safe_head_sha
  local original_decide_transition = restart_effects.decide_transition
  local original_mint_grant = restart_effects.mint_grant
  local decider_calls = {}
  local grant_mints = 0

  -- current_entity_state is the production snapshot provider; reviewing.version
  -- is copied directly from the event into the owner-decider intent.
  entity_lib.current_entity_state = function(...)
    local current = original_current_entity_state(...)
    sequence = sequence + 1
    table.insert(probes, {
      sequence = sequence,
      current = current,
      reviewing_version = reviewing_version,
    })
    return current
  end
  devloop_logging.log_cas_decision = function(dept, proposal_id, current, from_state, to_state, outcome, reason)
    sequence = sequence + 1
    table.insert(decisions, {
      sequence = sequence,
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
  payloads_predicates.verified_hand_off_state = function(M, repo, hand_off, expected)
    local state, reason = original_verified_hand_off_state(M, repo, hand_off, expected)
    sequence = sequence + 1
    table.insert(handoff_checks, {
      sequence = sequence,
      state = state,
      reason = reason,
      repo = repo,
      hand_off = hand_off,
      expected = expected,
      probe_count = #probes,
    })
    return state, reason
  end
  pr_safety.is_safe_head_sha = function(head_sha)
    local safe = original_is_safe_head_sha(head_sha)
    sequence = sequence + 1
    table.insert(boundary_calls, {
      sequence = sequence,
      head_sha = head_sha,
      safe = safe,
      probe_count = #probes,
      handoff_count = #handoff_checks,
    })
    return safe
  end
  restart_effects.decide_transition = function(snapshot, intent)
    local decision = original_decide_transition(snapshot, intent)
    table.insert(decider_calls, {
      snapshot = snapshot,
      intent = intent,
      decision = decision,
    })
    return decision
  end
  restart_effects.mint_grant = function(...)
    grant_mints = grant_mints + 1
    return original_mint_grant(...)
  end

  local ok, result = pcall(run)
  restart_effects.mint_grant = original_mint_grant
  restart_effects.decide_transition = original_decide_transition
  pr_safety.is_safe_head_sha = original_is_safe_head_sha
  payloads_predicates.verified_hand_off_state = original_verified_hand_off_state
  devloop_logging.log_cas_decision = original_log_cas
  entity_lib.current_entity_state = original_current_entity_state
  if not ok then
    error(result, 0)
  end
  return result, probes, decisions, handoff_checks, boundary_calls, decider_calls, grant_mints
end

local function handoff_evidence(handoff_checks)
  if #handoff_checks == 0 then
    return nil
  end
  return {
    status = handoff_checks[#handoff_checks].state ~= nil and "valid" or "invalid",
  }
end

local function evidence_from_observations(probe, handoff_checks)
  return {
    current = probe.current,
    reviewing_version = probe.reviewing_version,
    handoff = handoff_evidence(handoff_checks),
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

local function find_decision(decisions, outcome)
  for _, decision in ipairs(decisions) do
    if decision.outcome == outcome then
      return decision
    end
  end
  return nil
end

local function frozen_old_admission(probe, handoff_checks)
  if probe == nil then
    return { status = "pre-cas", reason_code = "cas-probe-not-reached" }
  end
  local preliminary = frozen_old_reviewing_transition_status(probe.current, probe.reviewing_version)
  local handoff = handoff_evidence(handoff_checks)
  if (preliminary == "pending" or preliminary == "version-mismatch")
    and handoff
    and handoff.status == "valid" then
    return {
      status = "apply",
      reason_code = "verified-own-reviewing-hand-off",
      cas_outcome = "apply(verified-own-reviewing-hand-off)",
    }
  end
  if preliminary == "version-mismatch" then
    return { status = "stale", reason_code = "version-mismatch", cas_outcome = "skip-stale(version-mismatch)" }
  end
  if preliminary == "pending" then
    return { status = "pending", reason_code = "reviewing-marker-not-visible", cas_outcome = "retry-pending(reviewing marker not yet visible)" }
  end
  if preliminary == "stale" then
    return { status = "stale", reason_code = "advanced-or-diverged", cas_outcome = "skip-stale/diverged" }
  end
  return { status = "apply", reason_code = "apply", cas_outcome = "applied" }
end

local function post_admission_disposition(result, boundary_reached)
  if not boundary_reached then
    return "not-admitted"
  end
  if #(result.raises or {}) > 0 then
    return "effect-emitted"
  end
  return "admitted-no-effect"
end

local function reviewing_event(version, with_handoff)
  local event = h.reviewing({ version = version })
  if with_handoff then
    event.reviewing_hand_off = {
      kind = "own-state-marker",
      proposal_id = event.proposal_id,
      state = "reviewing",
      marker_version = event.version,
      event_version = event.version,
      stage_rank = core.stage_rank("reviewing"),
      comment_id = HANDOFF_COMMENT_ID,
    }
  end
  return event
end

local function fixture_comments(fixture, event)
  local comments = {
    m_builders.pr_origin_marker(
      event.proposal_id,
      tostring(ISSUE_NUMBER),
      BRANCH,
      event.version,
      BASE_BRANCH
    ),
  }
  if fixture.current_state ~= nil then
    table.insert(comments, core.state_marker(
      event.proposal_id,
      fixture.current_state,
      fixture.current_version
    ))
  end
  return comments
end

local function mock_case(fixture, event)
  local comments = fixture_comments(fixture, event)
  h.mock_bot_env()
  h.mock_context_bundle(event)
  h.mock_default_issue_claim(REPO, ISSUE_NUMBER)
  h.mock_issue_review({ "fkst-dev:reviewing" }, comments)
  h.mock_pr_origin_for({
    repo = REPO,
    number = PR_NUMBER,
    comments = comments,
    head = BRANCH,
    head_sha = HEAD_SHA,
    state = "OPEN",
    base_branch = BASE_BRANCH,
  })
  t.mock_command("/worktrees/devloop-", {
    stdout = "",
    stderr = "",
    exit_code = 1,
  })
  if fixture.valid_handoff then
    t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/" .. HANDOFF_COMMENT_ID .. "'", {
      stdout = '{"body":"' .. h.json_string(core.state_marker(
        event.proposal_id,
        "reviewing",
        event.version
      )) .. '","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
  elseif fixture.invalid_handoff then
    -- Same marker body, but an UNTRUSTED comment author: state_marker_comment_verified
    -- rejects it (comment-author-untrusted), so verified_hand_off_state returns nil and
    -- the hand-off does NOT override the pending/version-mismatch probe.
    t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/" .. HANDOFF_COMMENT_ID .. "'", {
      stdout = '{"body":"' .. h.json_string(core.state_marker(
        event.proposal_id,
        "reviewing",
        event.version
      )) .. '","user":{"login":"not-the-devloop-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
  end
end

local function run_real_department(event)
  local raises = {}
  local original_raise = raise
  raise = function(queue, payload)
    table.insert(raises, { queue = queue, payload = payload })
  end
  local ok, failure = pcall(review_pr_department.pipeline, {
    queue = "devloop_reviewing",
    payload = event,
  })
  raise = original_raise
  return {
    exit_code = ok and 0 or 1,
    error = ok and nil or tostring(failure),
    raises = raises,
  }
end

local FIXTURES = {
  {
    case_id = "reviewing_base_equal_applies",
    name = "reviewing-base-equal",
    current_state = "reviewing",
    current_version = V_EQUAL,
    event_version = V_EQUAL,
    boundary_reached = true,
    admission_status = "apply",
    admission_reason = "apply",
    log_outcome = "applied",
    post_admission_disposition = "effect-emitted",
  },
  {
    case_id = "reviewing_different_version_without_handoff_is_stale",
    name = "reviewing-version-mismatch",
    current_state = "reviewing",
    current_version = V_EQUAL,
    event_version = V_DIFFERENT,
    admission_status = "stale",
    admission_reason = "version-mismatch",
    log_outcome = "skip-stale(version-mismatch)",
  },
  {
    case_id = "reviewing_different_version_with_valid_handoff_applies",
    name = "reviewing-version-mismatch-valid-handoff",
    current_state = "reviewing",
    current_version = V_EQUAL,
    event_version = V_DIFFERENT,
    valid_handoff = true,
    boundary_reached = true,
    admission_status = "apply",
    admission_reason = "verified-own-reviewing-hand-off",
    log_outcome = "apply(verified-own-reviewing-hand-off)",
    post_admission_disposition = "effect-emitted",
  },
  {
    -- present-but-INVALID hand-off: verification is really called but fails (untrusted
    -- author), so the hand-off does NOT override the version-mismatch probe. Guards the
    -- regression where the catalog wrongly treats an "invalid" hand-off as an override.
    case_id = "reviewing_different_version_with_invalid_handoff_is_stale",
    name = "reviewing-version-mismatch-invalid-handoff",
    current_state = "reviewing",
    current_version = V_EQUAL,
    event_version = V_DIFFERENT,
    invalid_handoff = true,
    admission_status = "stale",
    admission_reason = "version-mismatch",
    log_outcome = "skip-stale(version-mismatch)",
  },
  {
    case_id = "earlier_state_with_valid_handoff_applies",
    name = "earlier-state-valid-handoff",
    current_state = "pr-open",
    current_version = V_EQUAL,
    event_version = V_EQUAL,
    valid_handoff = true,
    boundary_reached = true,
    admission_status = "apply",
    admission_reason = "verified-own-reviewing-hand-off",
    log_outcome = "apply(verified-own-reviewing-hand-off)",
    post_admission_disposition = "effect-emitted",
  },
  {
    case_id = "earlier_state_without_handoff_is_pending",
    name = "earlier-state-pending",
    current_state = "pr-open",
    current_version = V_EQUAL,
    event_version = V_EQUAL,
    expected_exit_code = 1,
    admission_status = "pending",
    admission_reason = "reviewing-marker-not-visible",
    log_outcome = "retry-pending(reviewing marker not yet visible)",
  },
  {
    case_id = "later_state_is_stale",
    name = "later-state-stale",
    current_state = "merge-ready",
    current_version = V_EQUAL,
    event_version = V_EQUAL,
    admission_status = "stale",
    admission_reason = "advanced-or-diverged",
    log_outcome = "skip-stale/diverged",
  },
  {
    case_id = "missing_marker_is_pending",
    name = "missing-marker-pending",
    current_state = nil,
    current_version = nil,
    event_version = V_EQUAL,
    expected_exit_code = 1,
    admission_status = "pending",
    admission_reason = "reviewing-marker-not-visible",
    log_outcome = "retry-pending(reviewing marker not yet visible)",
  },
  {
    case_id = "safe_equal_raw_different_applies",
    name = "safe-equal-raw-different",
    current_state = "reviewing",
    current_version = V_SAFE_EQUAL_CURRENT,
    event_version = V_SAFE_EQUAL_EVENT,
    boundary_reached = true,
    admission_status = "apply",
    admission_reason = "apply",
    log_outcome = "applied",
    post_admission_disposition = "effect-emitted",
  },
}

local function assert_case(fixture)
  local event = reviewing_event(fixture.event_version, fixture.valid_handoff or fixture.invalid_handoff)
  mock_case(fixture, event)
  local result, probes, decisions, handoff_checks, boundary_calls, decider_calls, grant_mints = observe_department(event.version, function()
    return run_real_department(event)
  end)

  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.name .. ": department exit code")
  t.eq(#probes, 1, fixture.name .. ": current-state provider probe count")
  local probe = probes[1]
  t.eq(probe.current.state, fixture.current_state, fixture.name .. ": probe current state")
  t.eq(probe.current.version, fixture.current_version, fixture.name .. ": probe current version")
  t.eq(probe.reviewing_version, event.version, fixture.name .. ": probe event reviewing version")

  local expected_handoff_count = (fixture.valid_handoff or fixture.invalid_handoff) and 1 or 0
  t.eq(#handoff_checks, expected_handoff_count, fixture.name .. ": handoff verification count")
  if fixture.valid_handoff or fixture.invalid_handoff then
    local handoff = handoff_checks[1]
    t.is_true(handoff.sequence > probe.sequence, fixture.name .. ": handoff follows current-state probe")
    t.eq(handoff.probe_count, 1, fixture.name .. ": handoff sees one probe")
    t.eq(handoff.repo, REPO, fixture.name .. ": handoff repository")
    t.eq(handoff.expected.proposal_id, event.proposal_id, fixture.name .. ": handoff proposal")
    t.eq(handoff.expected.state, "reviewing", fixture.name .. ": handoff expected state")
    t.eq(handoff.expected.marker_version, event.version, fixture.name .. ": handoff marker version")
    t.eq(handoff.expected.event_version, event.version, fixture.name .. ": handoff event version")
    if fixture.valid_handoff then
      t.is_true(handoff.state ~= nil, fixture.name .. ": real handoff verification succeeds")
    else
      -- present-but-invalid hand-off: verification is really invoked but fails
      -- (untrusted comment author), so no override -> handoff evidence is "invalid".
      t.is_true(handoff.state == nil, fixture.name .. ": real handoff verification fails")
    end
  end

  local boundary_reached = #boundary_calls > 0
  t.eq(boundary_reached, fixture.boundary_reached == true, fixture.name .. ": admission boundary reach")
  if boundary_reached then
    t.eq(#boundary_calls, 1, fixture.name .. ": admission boundary call count")
    t.eq(boundary_calls[1].probe_count, 1, fixture.name .. ": boundary follows one probe")
    t.eq(boundary_calls[1].handoff_count, expected_handoff_count, fixture.name .. ": boundary follows handoff path")
    t.eq(boundary_calls[1].head_sha, HEAD_SHA, fixture.name .. ": boundary head sha")
    t.eq(boundary_calls[1].safe, true, fixture.name .. ": boundary safe-head result")
  end

  local decision = find_decision(decisions, fixture.log_outcome)
  t.is_true(decision ~= nil, fixture.name .. ": expected observable CAS log")
  t.eq(decision.dept, "review_pr", fixture.name .. ": CAS decision department")
  t.eq(decision.proposal_id, event.proposal_id, fixture.name .. ": CAS decision proposal")
  t.eq(decision.from_state, "reviewing", fixture.name .. ": logged source state")
  t.eq(decision.to_state, "review-proposal", fixture.name .. ": logged target effect")
  t.eq(decision.probe_count, 1, fixture.name .. ": CAS log follows probe")

  local evidence = evidence_from_observations(probe, handoff_checks)
  t.eq(evidence.current, probe.current, fixture.name .. ": catalog current is observed current")
  t.eq(evidence.reviewing_version, event.version, fixture.name .. ": catalog version is event field")
  local expected_handoff_status = fixture.valid_handoff and "valid"
    or (fixture.invalid_handoff and "invalid" or nil)
  t.eq(evidence.handoff and evidence.handoff.status or nil, expected_handoff_status, fixture.name .. ": catalog handoff status")
  local observed = frozen_old_admission(probe, handoff_checks)
  local resolved = catalog.resolve(POLICY_ID, evidence, projection)
  t.eq(resolved.status, observed.status, fixture.name .. ": admission status parity")
  t.eq(resolved.reason_code, observed.reason_code, fixture.name .. ": admission reason parity")
  t.eq(observed.status, fixture.admission_status, fixture.name .. ": observed admission status")
  t.eq(observed.reason_code, fixture.admission_reason, fixture.name .. ": observed admission reason")
  t.eq(resolved.status, fixture.admission_status, fixture.name .. ": catalog admission status")
  t.eq(resolved.reason_code, fixture.admission_reason, fixture.name .. ": catalog admission reason")
  t.eq(resolved.cas_outcome, observed.cas_outcome, fixture.name .. ": frozen OLD CAS outcome parity")

  local expected_decider_calls = expected_handoff_count == 1 and 2 or 1
  t.eq(#decider_calls, expected_decider_calls, fixture.name .. ": production owner-decider call count")
  for index, call in ipairs(decider_calls) do
    t.eq(call.intent.semantic_variant, SEMANTIC_VARIANT, fixture.name .. ": decider semantic variant " .. tostring(index))
    t.eq(call.intent.source_boundary, SOURCE_BOUNDARY, fixture.name .. ": decider source boundary " .. tostring(index))
    t.eq(call.intent.target, "reviewing", fixture.name .. ": decider target " .. tostring(index))
    t.eq(call.intent.reviewing_version, event.version, fixture.name .. ": decider reviewing version " .. tostring(index))
    t.eq(call.snapshot.current.state, probe.current.state, fixture.name .. ": sealed current state " .. tostring(index))
    t.eq(call.snapshot.current.version, probe.current.version, fixture.name .. ": sealed current version " .. tostring(index))
  end
  t.eq(decider_calls[1].intent.handoff, nil, fixture.name .. ": preliminary admission has no handoff overlay")
  if expected_handoff_count == 1 then
    t.eq(decider_calls[2].intent.handoff.status, expected_handoff_status,
      fixture.name .. ": verified handoff evidence reaches production decider")
  end
  local production_decision = decider_calls[#decider_calls].decision
  assert_bidirectional(production_decision, observed, "reason_code", fixture.name .. ": production-vs-frozen-old")
  assert_bidirectional(production_decision, observed, "status", fixture.name .. ": production-vs-frozen-old")
  assert_bidirectional(production_decision, observed, "cas_outcome", fixture.name .. ": production-vs-frozen-old")
  if production_decision.status == "apply" then
    t.eq(production_decision.effect_entitlement_id,
      "github-devloop-pr/reviewing/entry/review_receiver/apply",
      fixture.name .. ": admission-only entitlement identity")
    t.eq(#production_decision.granted_effect_ids, 0, fixture.name .. ": review activation grants no effects")
  else
    t.eq(production_decision.effect_entitlement_id, nil,
      fixture.name .. ": non-applying admission has no entitlement")
    t.eq(production_decision.granted_effect_ids, nil,
      fixture.name .. ": non-applying admission grants no effects")
  end
  t.eq(grant_mints, 0, fixture.name .. ": grantless proposal mints no grant")

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
      evidence_refs = { "review-pr-cas-probe", "reviewing-hand-off-verification" },
      reviewing_version = event.version,
      handoff = handoff_evidence(handoff_checks),
    })
  end)
  assert_bidirectional(shadow, resolved, "reason_code", fixture.name)
  assert_bidirectional(shadow, resolved, "status", fixture.name)
  assert_bidirectional(shadow, resolved, "cas_outcome", fixture.name)
  t.eq(
    shadow.edge_id,
    "github-devloop-pr/reviewing/entry/review_receiver",
    fixture.name .. ": selected edge"
  )
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
  t.eq(shadow_evidence.current.state, probe.current.state, fixture.name .. ": evidence current state")
  t.eq(shadow_evidence.current.version, probe.current.version, fixture.name .. ": evidence current version")
  t.eq(shadow_evidence.reviewing_version, event.version, fixture.name .. ": evidence reviewing version")
  t.eq(
    shadow_evidence.handoff and shadow_evidence.handoff.status or nil,
    expected_handoff_status,
    fixture.name .. ": evidence handoff status"
  )
  t.eq(shadow_evidence.variant, nil, fixture.name .. ": resolve-based evidence has no variant")
  t.eq(shadow_evidence.incoming_version, nil, fixture.name .. ": resolve-based evidence has no incoming version")
  t.eq(shadow_evidence.overlay_version, nil, fixture.name .. ": resolve-based evidence has no overlay version")

  local expected_effect_count = boundary_reached and 1 or 0
  t.eq(#result.raises, expected_effect_count, fixture.name .. ": captured effect count")
  if expected_effect_count == 1 then
    t.eq(result.raises[1].queue, "consensus.proposal", fixture.name .. ": captured effect queue")
    t.eq(result.raises[1].payload.schema, "consensus.proposal.v1", fixture.name .. ": captured effect schema")
  end
  t.eq(
    post_admission_disposition(result, boundary_reached),
    fixture.post_admission_disposition or "not-admitted",
    fixture.name .. ": post-admission disposition"
  )
end

local function assert_malformed_is_pre_cas_and_catalog_illegal()
  local malformed = h.reviewing({ version = 42 })
  local result, probes, decisions, handoff_checks, boundary_calls, decider_calls, grant_mints = observe_department(malformed.version, function()
    return run_real_department(malformed)
  end)

  t.eq(result.exit_code, 0, "review-activation-malformed: production rejects unsupported payload")
  t.eq(#probes, 0, "review-activation-malformed: production rejects before CAS")
  t.eq(#handoff_checks, 0, "review-activation-malformed: handoff verification is not reached")
  t.eq(#boundary_calls, 0, "review-activation-malformed: admission boundary is not reached")
  t.eq(#decider_calls, 0, "review-activation-malformed: owner decider is not reached")
  t.eq(grant_mints, 0, "review-activation-malformed: no grants")
  t.eq(#result.raises, 0, "review-activation-malformed: no effects")
  t.eq(#decisions, 1, "review-activation-malformed: rejection decision count")
  t.eq(decisions[1].outcome, "skip-foreign(payload)", "review-activation-malformed: rejection outcome")

  local resolved = catalog.resolve(POLICY_ID, {
    current = { state = "reviewing", version = V_EQUAL },
    reviewing_version = malformed.version,
  }, projection)
  t.eq(resolved.status, "illegal", "review-activation-malformed: catalog status")
  t.eq(resolved.reason_code, "invalid-evidence", "review-activation-malformed: catalog reason")
  t.eq(resolved.cas_outcome, "illegal(invalid-evidence)", "review-activation-malformed: catalog fails closed")
end

local tests = {
  test_review_activation_malformed_payload_is_pre_cas_and_catalog_illegal =
    assert_malformed_is_pre_cas_and_catalog_illegal,
}
for _, fixture in ipairs(FIXTURES) do
  tests["test_review_activation_" .. fixture.case_id] = function()
    if fixture.name == "safe-equal-raw-different" then
      t.is_true(fixture.current_version ~= fixture.event_version, fixture.name .. ": raw versions differ")
      t.eq(
        transition_version.strip_suffixes(fixture.current_version),
        transition_version.strip_suffixes(fixture.event_version),
        fixture.name .. ": stripped versions are equal"
      )
    end
    assert_case(fixture)
  end
end

return tests
