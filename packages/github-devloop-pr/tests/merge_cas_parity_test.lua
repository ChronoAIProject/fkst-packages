-- Non-circularity contract: production truth comes from the real merge
-- department's owner-decider and grant-gated synchronous marker path. Frozen
-- OLD truth comes from the former production branch copied below and the
-- byte-unchanged observation corpus; no owner decision computes OLD truth.

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
local h = require("tests.devloop_helpers")
local restart_authority = require("core.restart_authority")
local restart_effects = require("core.restart_effects")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)
local merge_department = require("departments.merge.main")

local POLICY_ID = "cas.legacy_merge_v1"
local VARIANT = "merge_ready_or_merging_to_merging"
local OWNER = core.restart_package_name
local MERGE_CORPUS_PATH = "migration/intent_bounded_replay/corpus/pr-merge.json"
local MERGE_NEW_TRACE_PATH = ".fkst/run/r9-pr-merge-new-trace.json"
local COMMENT_EFFECT_ID = "github-proxy.github_pr_comment_request"
local V_OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local V_ORDERING_EQUAL_CURRENT = V_EQUAL .. "/loop/01"
local V_ORDERING_EQUAL_INCOMING = V_EQUAL .. "/loop/1"

local function observe_department(run)
  local probes = {}
  local decisions = {}
  local boundary_calls = {}
  local grant_mints = {}
  local grant_verifications = {}
  local timeline = {}
  local admission_writes = observation_support.json_array()
  local original_log_cas = devloop_logging.log_cas_decision
  local original_merge_ready_fact = m_facts.merge_ready_fact
  local original_decide_transition = restart_effects.decide_transition
  local original_mint_grant = restart_effects.mint_grant
  local original_verify_grant = restart_effects.verify_grant
  local original_pr_comment = core.gh_pr_comment
  local original_verified_merge = core.run_verified_pr_merge

  restart_effects.decide_transition = function(snapshot, intent)
    local decision = original_decide_transition(snapshot, intent)
    table.insert(probes, {
      current = snapshot.current,
      from_states = { "merge-ready", "merging" },
      to_state = intent.target,
      incoming_version = intent.incoming_version,
      target_version = intent.target_version,
      outcome = devloop_state.cyclic_transition_status(
        snapshot.current, { "merge-ready", "merging" }, "merging",
        intent.incoming_version, intent.target_version
      ),
      snapshot = snapshot,
      intent = intent,
      decision = decision,
    })
    table.insert(timeline, { kind = "decide", status = decision.status })
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
    table.insert(timeline, { kind = "mint", sink_id = sink_id })
    return grant
  end
  restart_effects.verify_grant = function(grant, effect_id, snapshot)
    local verified = original_verify_grant(grant, effect_id, snapshot)
    table.insert(grant_verifications, {
      grant = grant,
      effect_id = effect_id,
      snapshot = snapshot,
      verified = verified,
    })
    table.insert(timeline, { kind = "verify", effect_id = effect_id, verified = verified })
    return verified
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
  m_facts.merge_ready_fact = function(comments, proposal_id, version, pr_number, head_sha)
    table.insert(boundary_calls, {
      comments = comments,
      proposal_id = proposal_id,
      version = version,
      pr_number = pr_number,
      head_sha = head_sha,
    })
    return original_merge_ready_fact(comments, proposal_id, version, pr_number, head_sha)
  end
  core.gh_pr_comment = function(repo, pr_number, body_path, timeout)
    table.insert(timeline, { kind = "synchronous-comment" })
    table.insert(admission_writes, {
      queue = COMMENT_EFFECT_ID,
      payload = { body = file.read(body_path) },
    })
    return original_pr_comment(repo, pr_number, body_path, timeout)
  end
  core.run_verified_pr_merge = function(options)
    local result = table.pack(original_verified_merge(options))
    table.insert(timeline, { kind = "verified-merge-return" })
    return table.unpack(result, 1, result.n)
  end

  local ok, result = pcall(run)
  core.run_verified_pr_merge = original_verified_merge
  core.gh_pr_comment = original_pr_comment
  m_facts.merge_ready_fact = original_merge_ready_fact
  devloop_logging.log_cas_decision = original_log_cas
  restart_effects.verify_grant = original_verify_grant
  restart_effects.mint_grant = original_mint_grant
  restart_effects.decide_transition = original_decide_transition
  if not ok then
    error(result, 0)
  end
  return result, probes, decisions, boundary_calls, admission_writes,
    grant_mints, grant_verifications, timeline
end

local function current_fact(state, version)
  return { state = state, version = version }
end

-- Frozen from merge_executor.lua's former direct cyclic CAS and exact branch order.
local function frozen_old_admission(probe)
  local current = probe.current
  local incoming = probe.incoming_version
  local transition = devloop_state.cyclic_transition_status(
    current, { "merge-ready", "merging" }, "merging", incoming
  )
  if current.state ~= "merge-ready" and current.state ~= "merging" and current.state ~= "merged" then
    return { status = "stale", reason_code = "from-state-mismatch",
      cas_outcome = "skip-stale(from-state-mismatch)" }
  end
  if transition == "pending" then
    return { status = "pending", reason_code = "source-marker-not-visible",
      cas_outcome = devloop_state.cas_outcome(current, transition, incoming) }
  end
  if transition == "stale" then
    local reason = tostring(incoming or "") ~= tostring(current.version or "")
      and "incoming-version-older" or "advanced-or-diverged"
    return { status = "stale", reason_code = reason,
      cas_outcome = devloop_state.cas_outcome(current, transition, incoming) }
  end
  if transition == "idempotent" and current.state ~= "merging" then
    return { status = "stale", reason_code = "advanced-or-diverged",
      cas_outcome = devloop_state.cas_outcome(current, transition, incoming) }
  end
  if transition == "apply" and current.state ~= "merge-ready" then
    return { status = "stale", reason_code = "from-state-mismatch",
      cas_outcome = "skip-stale(from-state-mismatch)" }
  end
  if transition ~= "apply" and transition ~= "idempotent" then
    return { status = transition, reason_code = "advanced-or-diverged",
      cas_outcome = devloop_state.cas_outcome(current, transition, incoming) }
  end
  if tostring(current.version or "") ~= tostring(incoming or "") then
    return { status = "stale", reason_code = "version-mismatch",
      cas_outcome = "skip-stale(version-mismatch)" }
  end
  if transition == "idempotent" then
    return { status = "idempotent", reason_code = "already-at-target",
      cas_outcome = "skip-idempotent(already at to_state)" }
  end
  return { status = "apply", reason_code = "apply", cas_outcome = "applied" }
end

local function evidence_from_probe(probe)
  return {
    current = current_fact(probe.current.state, probe.current.version),
    variant = VARIANT,
    incoming_version = probe.incoming_version,
    target_version = probe.target_version,
    overlay_version = probe.incoming_version,
  }
end

local function observed_admission(probe)
  return frozen_old_admission(probe)
end

local function post_admission_disposition(result, decision, boundary_reached)
  if not boundary_reached then
    return "not-admitted"
  end
  if #(result.raises or {}) > 0 then
    return "effect-emitted"
  end
  local outcome = tostring(decision and decision.outcome or "")
  if outcome:find("merge-ready fact marker not visible", 1, true) ~= nil then
    return "merge-ready-fact-pending"
  end
  return "post-admission-no-effect"
end

local function run_real_department(event)
  local raises = {}
  local original_raise = raise
  raise = function(queue, payload)
    table.insert(raises, { queue = queue, payload = payload })
  end
  local ok, failure = pcall(merge_department.pipeline, {
    queue = "devloop_merge_ready",
    payload = event,
  })
  raise = original_raise
  return {
    exit_code = ok and 0 or 1,
    error = ok and nil or tostring(failure),
    raises = raises,
  }
end

local function mock_current_pr(event, fixture)
  local comments = {}
  if fixture.current_state ~= nil then
    table.insert(comments, core.state_marker(event.proposal_id, fixture.current_state, fixture.current_version))
  end
  h.mock_bot_env()
  h.mock_write_env("")
  h.mock_default_issue_claim()
  h.mock_pr_merge(comments)
end

local function assert_catalog_matches_observed_decision(fixture)
  local event = h.merge_ready({ version = fixture.incoming_version })
  mock_current_pr(event, fixture)

  local result, probes, decisions, boundary_calls = observe_department(function()
    return run_real_department(event)
  end)

  t.eq(#probes, 1, fixture.name .. ": real department CAS probe count")
  local probe = probes[1]
  t.eq(probe.current.state, fixture.current_state, fixture.name .. ": probe current state")
  t.eq(probe.current.version, fixture.current_version, fixture.name .. ": probe current version")
  t.eq(probe.intent.semantic_variant, "handoff_to_merge_gate", fixture.name .. ": production semantic variant")
  t.eq(probe.intent.target, "merging", fixture.name .. ": production target state")
  t.eq(probe.to_state, "merging", fixture.name .. ": observed target state")
  t.eq(probe.incoming_version, fixture.incoming_version, fixture.name .. ": probe incoming version")
  t.eq(probe.target_version, nil, fixture.name .. ": probe target version")

  t.eq(#decisions, 1, fixture.name .. ": structured CAS decision count")
  local decision = decisions[1]
  t.eq(decision.dept, "merge", fixture.name .. ": CAS decision department")
  t.eq(decision.from_state, "merge-ready", fixture.name .. ": logged source state")
  t.eq(decision.to_state, "merging", fixture.name .. ": logged target state")
  t.is_true(type(decision.outcome) == "string", fixture.name .. ": legacy log outcome captured")
  t.is_true(type(decision.reason) == "string", fixture.name .. ": legacy log reason captured")

  local boundary_reached = #boundary_calls > 0
  t.eq(#boundary_calls, fixture.boundary_reached and 1 or 0, fixture.name .. ": admission boundary reach")
  if boundary_reached then
    t.eq(boundary_calls[1].proposal_id, event.proposal_id, fixture.name .. ": boundary proposal")
    t.eq(boundary_calls[1].version, event.version, fixture.name .. ": boundary version")
    t.eq(boundary_calls[1].pr_number, event.pr_number, fixture.name .. ": boundary PR")
    t.eq(boundary_calls[1].head_sha, event.reviewed_head_sha, fixture.name .. ": boundary head")
  end

  local observed = observed_admission(probe)
  local evidence = evidence_from_probe(probe)
  t.eq(evidence.current.state, probe.current.state, fixture.name .. ": catalog current state comes from probe")
  t.eq(evidence.current.version, probe.current.version, fixture.name .. ": catalog current version comes from probe")
  t.eq(evidence.incoming_version, probe.incoming_version, fixture.name .. ": catalog incoming version comes from probe")
  t.eq(evidence.target_version, probe.target_version, fixture.name .. ": catalog target version comes from probe")
  t.eq(evidence.overlay_version, probe.incoming_version, fixture.name .. ": catalog overlay version comes from probe")
  local actual = catalog.resolve(POLICY_ID, evidence, projection)
  t.eq(probe.decision.status, observed.status, fixture.name .. ": production owner status vs frozen OLD")
  t.eq(probe.decision.reason_code, observed.reason_code, fixture.name .. ": production owner reason vs frozen OLD")
  t.eq(probe.decision.cas_outcome, observed.cas_outcome, fixture.name .. ": production owner outcome vs frozen OLD")
  t.eq(actual.status, observed.status, fixture.name .. ": catalog status vs frozen OLD")
  t.eq(actual.reason_code, observed.reason_code, fixture.name .. ": catalog reason vs frozen OLD")
  t.eq(actual.cas_outcome, observed.cas_outcome, fixture.name .. ": catalog outcome vs frozen OLD")
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
  t.eq(#result.raises, fixture.effect_count or 0, fixture.name .. ": captured effect count")

  local disposition = post_admission_disposition(result, decision, boundary_reached)
  t.eq(disposition, fixture.post_admission_disposition or "not-admitted", fixture.name .. ": post-admission disposition")
  if fixture.legacy_log_outcome ~= nil then
    t.eq(decision.outcome, fixture.legacy_log_outcome, fixture.name .. ": legacy log outcome")
  end
  return {
    evidence = evidence,
    observed = observed,
  }
end

local function assert_bidirectional(actual, expected, field, context)
  t.eq(actual[field], expected[field], context .. ": shadow-to-old " .. field)
  t.eq(expected[field], actual[field], context .. ": old-to-shadow " .. field)
end

local function assert_shadow_parity(fixture)
  local production = assert_catalog_matches_observed_decision(fixture)
  local sealed = restart_authority.seal_snapshot({
    owner = OWNER,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
  })
  local shadow = restart_authority.decide_transition(sealed, {
    semantic_variant = "handoff_to_merge_gate",
    target = "merging",
    incoming_version = fixture.incoming_version,
    target_version = production.evidence.target_version,
    overlay_version = production.evidence.overlay_version,
  })

  assert_bidirectional(shadow, production.observed, "reason_code", fixture.name)
  assert_bidirectional(shadow, production.observed, "status", fixture.name)
  assert_bidirectional(shadow, production.observed, "cas_outcome", fixture.name)
  t.eq(
    shadow.edge_id,
    "github-devloop-pr/merge-ready/entry/handoff_to_merge_gate",
    fixture.name .. ": selected edge"
  )
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.evidence.facts.source, "merge-ready", fixture.name .. ": selected edge source")
  t.eq(shadow.evidence.facts.target, "merging", fixture.name .. ": selected edge target")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
end

local function assert_pre_cas_rejection(name, payload, expected_reason_code)
  local result, probes, _, boundary_calls = observe_department(function()
    return run_real_department(payload)
  end)
  t.eq(result.exit_code, 0, name .. ": unsupported payload is rejected without a pipeline error")
  t.eq(#probes, 0, name .. ": invalid production input must not reach CAS")
  t.eq(#boundary_calls, 0, name .. ": invalid production input must not reach the admission boundary")
  local evidence = {
    current = current_fact("merge-ready", V_EQUAL),
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

local function assert_pre_cas_merged_marker_idempotency()
  local name = "merge-terminal-marker-idempotency"
  local event = h.merge_ready({ version = V_EQUAL })
  local comments = {
    core.state_marker(event.proposal_id, "merged", event.version),
    m_builders.merged_marker(core, event.proposal_id, event.pr_number, event.version, event.reviewed_head_sha),
  }
  h.mock_bot_env()
  h.mock_write_env("")
  h.mock_default_issue_claim()
  h.mock_pr_merge(comments)
  local merge_calls_before = h.count_calls("gh pr merge")

  local result, probes, decisions, boundary_calls = observe_department(function()
    return run_real_department(event)
  end)

  t.eq(result.exit_code, 0, name .. ": department exit code")
  t.eq(#probes, 0, name .. ": terminal effect-idempotency precedes the cyclic CAS probe")
  t.eq(#boundary_calls, 0, name .. ": terminal effect-idempotency precedes the admission boundary")
  t.eq(#result.raises, 0, name .. ": no effect emitted")
  t.eq(h.count_calls("gh pr merge"), merge_calls_before, name .. ": merge effect not invoked")
  t.eq(#decisions, 1, name .. ": structured decision count")
  t.eq(decisions[1].current.state, "merged", name .. ": logged current state")
  t.eq(decisions[1].current.version, V_EQUAL, name .. ": logged current version")
  t.eq(decisions[1].outcome, "skip-idempotent(already at to_state)", name .. ": legacy outcome")
  t.eq(decisions[1].reason, "merged marker already visible", name .. ": legacy reason")
  -- Deliberately no catalog.resolve call: the catalog models CAS admission, not
  -- this trusted merged-marker effect-idempotency guard before the CAS probe.
end

local TRACE_EDGE_ID = OWNER .. "/merge-ready/entry/handoff_to_merge_gate"
local TRACE_FIXTURES = {
  {
    fixture_id = "source-equal-apply",
    current_state = "merge-ready",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    exercise_marker_write = true,
    old_marker_write_count = 1,
  },
  {
    fixture_id = "source-newer-pending",
    current_state = "merge-ready",
    current_version = V_EQUAL,
    incoming_version = V_NEWER,
  },
  {
    fixture_id = "source-older-stale",
    current_state = "merge-ready",
    current_version = V_EQUAL,
    incoming_version = V_OLDER,
  },
  {
    fixture_id = "target-incomplete-idempotent",
    current_state = "merging",
    current_version = V_EQUAL,
    incoming_version = V_EQUAL,
    exercise_marker_write = true,
    old_marker_write_count = 1,
  },
}

local function trace_pr_comments(event, current_state)
  local comments = h.merge_comments(event)
  if current_state == "merging" then
    table.insert(comments, core.state_marker(event.proposal_id, "merging", event.version))
  end
  return comments
end

local function trace_origin_marker(event)
  return m_builders.pr_origin_marker(
    event.proposal_id,
    "42",
    "devloop-owner-repo-42-01HY",
    event.version,
    "dev"
  )
end

local function mock_marker_write_path(event, fixture)
  local comments = trace_pr_comments(event, fixture.current_state)
  h.mock_bot_env()
  h.mock_write_env("1")
  h.mock_write_env("1")
  h.mock_default_issue_claim()
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&base=dev&per_page=100'", {
    stdout = '[{"number":7,"state":"open","base":{"ref":"dev"}}]\n',
    stderr = "",
    exit_code = 0,
  })
  h.mock_pr_normal_risk_diff_name_only()
  h.mock_pr_normal_risk_diff_name_only()
  h.mock_issue_merge({ "fkst-dev:" .. fixture.current_state }, comments)
  h.mock_pr_merge({ trace_origin_marker(event) })
  h.mock_issue_merge({ "fkst-dev:" .. fixture.current_state }, comments)
  h.mock_pr_merge(comments)
  h.mock_merging_comment()
end

local function trace_decision(decisions)
  for _, decision in ipairs(decisions) do
    if decision.dept == "merge"
      and decision.from_state == "merge-ready"
      and decision.to_state == "merging" then
      return decision
    end
  end
  return nil
end

local function timeline_index(timeline, kind)
  for index, item in ipairs(timeline) do
    if item.kind == kind then return index end
  end
  return nil
end

local function observe_old_trace_fixture(fixture)
  local event = h.merge_ready({ version = fixture.incoming_version })
  local original_verified_merge = core.run_verified_pr_merge
  if fixture.exercise_marker_write then
    mock_marker_write_path(event, fixture)
    core.run_verified_pr_merge = function(options)
      options.before_merge()
      return false, "merge-confirmation-pending", {}
    end
  else
    mock_current_pr(event, fixture)
  end

  local result, probes, decisions, boundary_calls, admission_writes,
    grant_mints, grant_verifications, timeline = observe_department(function()
      return run_real_department(event)
    end)
  core.run_verified_pr_merge = original_verified_merge

  t.eq(#probes, 1, fixture.fixture_id .. ": OLD production CAS probe count")
  local decision = trace_decision(decisions)
  t.is_true(decision ~= nil, fixture.fixture_id .. ": OLD production admission decision")
  local observed = observed_admission(probes[1])
  t.eq(probes[1].decision.status, observed.status,
    fixture.fixture_id .. ": production owner status vs frozen OLD")
  t.eq(probes[1].decision.reason_code, observed.reason_code,
    fixture.fixture_id .. ": production owner reason vs frozen OLD")
  t.eq(probes[1].decision.cas_outcome, observed.cas_outcome,
    fixture.fixture_id .. ": production owner outcome vs frozen OLD")
  t.eq(
    #admission_writes,
    fixture.old_marker_write_count or 0,
    fixture.fixture_id .. ": OLD direct merging-marker write count"
  )
  if #admission_writes > 0 then
    t.is_true(
      admission_writes[1].payload.body:find('state="merging"', 1, true) ~= nil,
      fixture.fixture_id .. ": production write is the merging state marker"
    )
    t.eq(#grant_mints, 1, fixture.fixture_id .. ": merging marker grant mint count")
    t.eq(grant_mints[1].sink_id, "comment:pr:merging-state",
      fixture.fixture_id .. ": merging marker grant sink")
    t.is_true(grant_mints[1].grant ~= nil, fixture.fixture_id .. ": merging marker grant minted")
    t.eq(#grant_verifications, 1, fixture.fixture_id .. ": merging marker grant verification count")
    t.eq(grant_verifications[1].effect_id, COMMENT_EFFECT_ID,
      fixture.fixture_id .. ": merging marker verified effect")
    t.eq(grant_verifications[1].snapshot, probes[1].snapshot,
      fixture.fixture_id .. ": merging marker verification snapshot binding")
    t.eq(grant_verifications[1].verified, true,
      fixture.fixture_id .. ": merging marker grant verified")
    local verify_index = timeline_index(timeline, "verify")
    local comment_index = timeline_index(timeline, "synchronous-comment")
    local merge_return_index = timeline_index(timeline, "verified-merge-return")
    t.eq(comment_index, verify_index + 1,
      fixture.fixture_id .. ": grant verifies immediately before synchronous marker post")
    t.is_true(comment_index < merge_return_index,
      fixture.fixture_id .. ": synchronous marker post precedes verified merge return")
  else
    t.eq(#grant_mints, 0, fixture.fixture_id .. ": no marker means no grant mint")
    t.eq(#grant_verifications, 0, fixture.fixture_id .. ": no marker means no grant verification")
  end
  return {
    event = event,
    observed = observed,
    admission_writes = admission_writes,
    result = result,
    decision = probes[1].decision,
  }
end

local function new_trace_fixture(fixture, production)
  local decided = production.decision
  local writes = decided.status == "apply"
    and observation_support.admission_trace_writes(
      production.admission_writes, "R9 PR merge trace"
    )
    or observation_support.json_array()
  return decided, writes
end

local function trace_artifact(corpus_hash, fixtures)
  return observation_support.admission_trace_artifact(
    "restart-pr-merge-trace.v1", OWNER, "pr-merge", corpus_hash, fixtures
  )
end

local function assert_merge_trace_equality()
  local corpus = json.decode(file.read(MERGE_CORPUS_PATH))
  local old_fixtures = observation_support.json_array()
  local new_fixtures = observation_support.json_array()
  for _, fixture in ipairs(TRACE_FIXTURES) do
    local production = observe_old_trace_fixture(fixture)
    local decided, new_writes = new_trace_fixture(fixture, production)
    table.insert(old_fixtures, corpus.fixtures[#old_fixtures + 1])
    table.insert(new_fixtures, observation_support.admission_trace_fixture(
      fixture, TRACE_EDGE_ID, decided.status, decided.reason_code,
      decided.cas_outcome, decided.effect_entitlement_id,
      decided.granted_effect_ids, new_writes
    ))
  end

  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  local new_trace = trace_artifact(corpus.artifact_sha256, new_fixtures)
  local canonical_json = observation_support.canonical_json
  t.eq(canonical_json(old_trace), canonical_json(corpus),
    "R9 PR merge frozen OLD observation corpus")
  t.eq(canonical_json(old_trace), canonical_json(new_trace),
    "R9 PR merge frozen OLD and production owner trace")
  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 PR merge trace could not create its artifact directory", 0)
  end
  file.write(MERGE_NEW_TRACE_PATH, canonical_json(new_trace) .. "\n")
  t.eq(canonical_json(new_trace), canonical_json(corpus),
    "R9 PR merge NEW semantic trace")
end

return {
  test_merge_source_equal_is_admitted_before_merge_ready_fact_guard = function()
    assert_shadow_parity({
      name = "merge-source-equal",
      current_state = "merge-ready",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      boundary_reached = true,
      expected_exit_code = 1,
      post_admission_disposition = "merge-ready-fact-pending",
      probe_outcome = "apply",
      admission_status = "apply",
      admission_reason_code = "apply",
      legacy_log_outcome = "retry-pending(merge-ready fact marker not visible)",
    })
  end,

  test_merge_target_equal_is_idempotent_before_merge_ready_fact_guard = function()
    assert_shadow_parity({
      name = "merge-target-equal",
      current_state = "merging",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      boundary_reached = true,
      expected_exit_code = 1,
      post_admission_disposition = "merge-ready-fact-pending",
      probe_outcome = "idempotent",
      admission_status = "idempotent",
      admission_reason_code = "already-at-target",
    })
  end,

  test_merge_source_older_is_stale = function()
    assert_shadow_parity({
      name = "merge-source-older",
      current_state = "merge-ready",
      current_version = V_EQUAL,
      incoming_version = V_OLDER,
      probe_outcome = "stale",
      admission_status = "stale",
      admission_reason_code = "incoming-version-older",
    })
  end,

  test_merge_source_newer_is_pending = function()
    assert_shadow_parity({
      name = "merge-source-newer",
      current_state = "merge-ready",
      current_version = V_EQUAL,
      incoming_version = V_NEWER,
      expected_exit_code = 1,
      probe_outcome = "pending",
      admission_status = "pending",
      admission_reason_code = "source-marker-not-visible",
    })
  end,

  test_merge_target_older_is_stale = function()
    assert_shadow_parity({
      name = "merge-target-older",
      current_state = "merging",
      current_version = V_EQUAL,
      incoming_version = V_OLDER,
      probe_outcome = "stale",
      admission_status = "stale",
      admission_reason_code = "incoming-version-older",
    })
  end,

  test_merge_target_newer_is_pending = function()
    assert_shadow_parity({
      name = "merge-target-newer",
      current_state = "merging",
      current_version = V_EQUAL,
      incoming_version = V_NEWER,
      expected_exit_code = 1,
      probe_outcome = "pending",
      admission_status = "pending",
      admission_reason_code = "source-marker-not-visible",
    })
  end,

  test_merge_missing_current_marker_is_stale_from_state_mismatch = function()
    assert_shadow_parity({
      name = "merge-current-missing",
      current_state = nil,
      current_version = nil,
      incoming_version = V_EQUAL,
      probe_outcome = "pending",
      admission_status = "stale",
      admission_reason_code = "from-state-mismatch",
      legacy_log_outcome = "skip-stale(from-state-mismatch)",
    })
  end,

  -- production's admissible-state guard (merge_executor.lua) fires on a missing marker
  -- BEFORE the pending/version branches, so a missing current is stale/from-state-mismatch
  -- regardless of the incoming version, not the pending retry a version-only model implies.
  test_merge_missing_current_older_version_is_stale_from_state_mismatch = function()
    assert_catalog_matches_observed_decision({
      name = "merge-current-missing-older",
      current_state = nil,
      current_version = nil,
      incoming_version = V_OLDER,
      probe_outcome = "pending",
      admission_status = "stale",
      admission_reason_code = "from-state-mismatch",
      legacy_log_outcome = "skip-stale(from-state-mismatch)",
    })
  end,

  test_merge_missing_current_newer_version_is_stale_from_state_mismatch = function()
    assert_catalog_matches_observed_decision({
      name = "merge-current-missing-newer",
      current_state = nil,
      current_version = nil,
      incoming_version = V_NEWER,
      probe_outcome = "pending",
      admission_status = "stale",
      admission_reason_code = "from-state-mismatch",
      legacy_log_outcome = "skip-stale(from-state-mismatch)",
    })
  end,

  test_merge_unrelated_state_is_stale = function()
    assert_shadow_parity({
      name = "merge-unrelated-stale",
      current_state = "blocked",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
    })
  end,

  test_merge_merged_without_terminal_fact_is_admissible_then_stale = function()
    assert_shadow_parity({
      name = "merge-merged-without-terminal-fact",
      current_state = "merged",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      probe_outcome = "stale",
      admission_status = "stale",
      admission_reason_code = "advanced-or-diverged",
      legacy_log_outcome = "skip-advanced-or-diverged",
    })
  end,

  test_merge_merged_without_terminal_fact_older_is_stale = function()
    assert_catalog_matches_observed_decision({
      name = "merge-merged-without-terminal-fact-older",
      current_state = "merged",
      current_version = V_EQUAL,
      incoming_version = V_OLDER,
      probe_outcome = "stale",
      admission_status = "stale",
      admission_reason_code = "incoming-version-older",
    })
  end,

  test_merge_merged_without_terminal_fact_newer_is_pending = function()
    assert_catalog_matches_observed_decision({
      name = "merge-merged-without-terminal-fact-newer",
      current_state = "merged",
      current_version = V_EQUAL,
      incoming_version = V_NEWER,
      expected_exit_code = 1,
      probe_outcome = "pending",
      admission_status = "pending",
      admission_reason_code = "source-marker-not-visible",
    })
  end,

  test_merge_non_admissible_predecessor_raw_apply_is_stale_from_state_mismatch = function()
    assert_shadow_parity({
      name = "merge-predecessor-equal",
      current_state = "reviewing",
      current_version = V_EQUAL,
      incoming_version = V_EQUAL,
      probe_outcome = "apply",
      admission_status = "stale",
      admission_reason_code = "from-state-mismatch",
      legacy_log_outcome = "skip-stale(from-state-mismatch)",
    })
  end,

  test_merge_ordering_equal_raw_different_is_stale_version_mismatch = function()
    t.is_true(
      V_ORDERING_EQUAL_CURRENT ~= V_ORDERING_EQUAL_INCOMING,
      "merge-ordering-equal-raw-different: fixture versions must be byte-different"
    )
    assert_shadow_parity({
      name = "merge-ordering-equal-raw-different",
      current_state = "merge-ready",
      current_version = V_ORDERING_EQUAL_CURRENT,
      incoming_version = V_ORDERING_EQUAL_INCOMING,
      probe_outcome = "apply",
      admission_status = "stale",
      admission_reason_code = "version-mismatch",
      legacy_log_outcome = "skip-stale(version-mismatch)",
    })
  end,

  test_merge_idempotent_ordering_equal_raw_different_is_stale_version_mismatch = function()
    assert_shadow_parity({
      name = "merge-idempotent-ordering-equal-raw-different",
      current_state = "merging",
      current_version = V_ORDERING_EQUAL_CURRENT,
      incoming_version = V_ORDERING_EQUAL_INCOMING,
      probe_outcome = "idempotent",
      admission_status = "stale",
      admission_reason_code = "version-mismatch",
      legacy_log_outcome = "skip-stale(version-mismatch)",
    })
  end,

  test_r9_pr_merge_old_equals_new_admission_trace = function()
    assert_merge_trace_equality()
  end,

  test_merge_malformed_evidence_and_payload_fail_closed_before_cas = function()
    local payload = h.merge_ready({ version = V_EQUAL })
    payload.version = 42
    assert_pre_cas_rejection("merge-malformed-version", payload, "invalid-evidence")
  end,

  test_merge_terminal_marker_idempotency_is_pre_cas_and_outside_catalog_parity = function()
    assert_pre_cas_merged_marker_idempotency()
  end,
}
