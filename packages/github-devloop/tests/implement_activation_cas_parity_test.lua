-- Non-circularity contract: production truth comes from the real implement
-- department's owner decision, the independently replayed legacy CAS probe, and
-- the first post-admission WIP guard. Catalog evidence is copied from observed
-- owner intent, never reconstructed from fixture versions. Handoff verification,
-- effects, liveness dedup, and legacy logs remain separate axes.

local catalog = require("devloop.restart_cas_catalog")
local context_bundle = require("devloop.context_bundle")
local observation_support = require("testkit_internal.old_behavior_observation_support")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local dispatch_live_run = require("devloop.dispatch_live_run")
local m_builders = require("devloop.markers.builders")
local m_mq = require("devloop.merge_queue")
local payloads_predicates = require("devloop.payloads.predicates")
local restart_authority = require("core.restart_authority")
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local requests_labels = require("devloop.requests.labels")
local requests_lifecycle = require("devloop.requests.lifecycle")
local workflow_codex = require("workflow_internal.codex")
local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local projection = owner_pending_projection.derive(core.restart_package_name, core.restart_transition_table(), inventories)
local implement_department = require("departments.implement.main")

local canonical_json = observation_support.canonical_json
local json_array = observation_support.json_array
local IMPLEMENT_ACTIVATION_CORPUS_PATH = "migration/intent_bounded_replay/corpus/implement-activation.json"
local IMPLEMENT_ACTIVATION_NEW_TRACE_PATH = ".fkst/run/r9-implement-activation-new-trace.json"

local OWNER = core.restart_package_name
local POLICY_ID = "cas.legacy_implement_activation_handoff_v1"
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local WIP_ISSUE_NUMBER = 51
local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local INTEGRATION_BRANCH = "integration/dev"
local V_OLDER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-02T01-02-03Z"
local V_EQUAL = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local V_NEWER = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
local V_ORDERING_EQUAL_CURRENT = V_EQUAL .. "/loop/01"
local V_ORDERING_EQUAL_INCOMING = V_EQUAL .. "/loop/1"

local variants = {
  ["ready\0implementing"] = "ready_to_implementing",
  ["impl-failed\0implementing"] = "impl_failed_to_implementing",
  ["blocked\0implementing"] = "blocked_to_implementing",
}

local decision_sources = {
  implementation_kicked_off = { state = "ready", kind = "versioned" },
  ["retry-implementation"] = { state = "impl-failed", kind = "versioned" },
  reimplement_blocked_open_pr = { state = "blocked", kind = "cyclic" },
  reimplement_blocked_implementing_timeout_without_pr = { state = "blocked", kind = "cyclic" },
}

local function source_state_names(expected_states)
  local names = {}
  for _, expected in ipairs(expected_states or {}) do
    table.insert(names, type(expected) == "table" and expected.state or expected)
  end
  return names
end

local function probe_variant(from_states, to_state)
  if type(from_states) ~= "table" or #from_states ~= 1 then
    return nil
  end
  return variants[tostring(from_states[1]) .. "\0" .. tostring(to_state)]
end

local function observe_department(run, opts)
  opts = opts or {}
  local named_calls = {}
  local probes = {}
  local decisions = {}
  local handoff_checks = {}
  local boundary_calls = {}
  local serializer_calls = { comment = {}, label = {} }
  local sequence = 0
  local original_versioned = devloop_state.versioned_transition_status
  local original_cyclic = devloop_state.cyclic_transition_status
  local original_decide_transition = restart_effects.decide_transition
  local original_log_cas = devloop_logging.log_cas_decision
  local original_verified_hand_off_state = payloads_predicates.verified_hand_off_state
  local original_wip_capacity_allows_start = m_mq.wip_capacity_allows_start
  local original_dispatch_live_run_dedup = dispatch_live_run.dispatch_live_run_dedup
  local original_context_fetch_from_bundle = context_bundle.context_fetch_from_bundle
  local original_codex_dispatch = workflow_codex.dispatch
  local original_implementing_comment = requests_lifecycle.build_implementing_state_comment_request
  local original_implementing_label = requests_labels.build_implementing_label_request

  dispatch_live_run.dispatch_live_run_dedup = function()
    return false
  end
  if opts.stop_after_activation then
    context_bundle.context_fetch_from_bundle = function()
      return { kind = "external", ref = "owner/repo#issue/42" }
    end
    workflow_codex.dispatch = function()
      return { deferred = true, reason = "trace-stop-after-implementation-activation" }
    end
  end
  requests_lifecycle.build_implementing_state_comment_request = function(
      builder_core, repo, issue_number, ready, worktree, branch, base_branch,
      base_sha, attempt, started_at, exec_ref)
    table.insert(serializer_calls.comment, {
      core = builder_core,
      issue = { repo = repo, number = issue_number },
      ready = ready,
      worktree = worktree,
      branch = branch,
      base_branch = base_branch,
      base_sha = base_sha,
      attempt = attempt,
      started_at = started_at,
      exec_ref = exec_ref,
    })
    return original_implementing_comment(
      builder_core, repo, issue_number, ready, worktree, branch, base_branch,
      base_sha, attempt, started_at, exec_ref
    )
  end
  requests_labels.build_implementing_label_request = function(repo, issue_number, ready)
    table.insert(serializer_calls.label, {
      issue = { repo = repo, number = issue_number },
      ready = ready,
    })
    return original_implementing_label(repo, issue_number, ready)
  end
  devloop_state.versioned_transition_status = function(current, from_states, to_state, incoming_version, target_version)
    if to_state == "implementing" and probe_variant(from_states, to_state) ~= nil then
      error("implement production used retired direct versioned activation CAS", 0)
    end
    return original_versioned(current, from_states, to_state, incoming_version, target_version)
  end
  devloop_state.cyclic_transition_status = function(current, from_states, to_state, incoming_version, target_version)
    if to_state == "implementing" and probe_variant(from_states, to_state) ~= nil then
      error("implement production used retired direct cyclic activation CAS", 0)
    end
    return original_cyclic(current, from_states, to_state, incoming_version, target_version)
  end
  restart_effects.decide_transition = function(snapshot, intent)
    local decision = original_decide_transition(snapshot, intent)
    local source = decision_sources[intent.semantic_variant]
    if source ~= nil then
      local from_states = { source.state }
      local current = { state = snapshot.current.state, version = snapshot.current.version }
      local outcome = source.kind == "cyclic"
        and original_cyclic(current, from_states, "implementing", intent.incoming_version, intent.target_version)
        or original_versioned(current, from_states, "implementing", intent.incoming_version, intent.target_version)
      sequence = sequence + 1
      local named_call = {
        sequence = sequence,
        current = current,
        expected_states = from_states,
        marker_version = intent.incoming_version,
        outcome = outcome,
        index = #named_calls + 1,
      }
      table.insert(named_calls, named_call)
      sequence = sequence + 1
      table.insert(probes, {
        sequence = sequence,
        named_call = named_call,
        kind = source.kind,
        current = current,
        from_states = from_states,
        to_state = "implementing",
        incoming_version = intent.incoming_version,
        target_version = intent.target_version,
        phase = intent.phase,
        retry = intent.retry,
        outcome = outcome,
        variant = probe_variant(from_states, "implementing"),
      })
    end
    return decision
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
    })
    return state, reason
  end
  m_mq.wip_capacity_allows_start = function(M, repo, current_issue_number)
    local allowed, reason, count, maximum = original_wip_capacity_allows_start(M, repo, current_issue_number)
    sequence = sequence + 1
    table.insert(boundary_calls, {
      sequence = sequence,
      repo = repo,
      issue_number = current_issue_number,
      allowed = allowed,
      reason = reason,
      count = count,
      maximum = maximum,
    })
    return allowed, reason, count, maximum
  end

  local ok, result = pcall(run)
  requests_labels.build_implementing_label_request = original_implementing_label
  requests_lifecycle.build_implementing_state_comment_request = original_implementing_comment
  workflow_codex.dispatch = original_codex_dispatch
  context_bundle.context_fetch_from_bundle = original_context_fetch_from_bundle
  dispatch_live_run.dispatch_live_run_dedup = original_dispatch_live_run_dedup
  m_mq.wip_capacity_allows_start = original_wip_capacity_allows_start
  payloads_predicates.verified_hand_off_state = original_verified_hand_off_state
  devloop_logging.log_cas_decision = original_log_cas
  restart_effects.decide_transition = original_decide_transition
  devloop_state.cyclic_transition_status = original_cyclic
  devloop_state.versioned_transition_status = original_versioned
  if not ok then
    error(result, 0)
  end
  return result, named_calls, probes, decisions, handoff_checks, boundary_calls, serializer_calls
end

local function evidence_from_probe(probe, handoff_checks)
  local definition = catalog.definition(POLICY_ID)
  local variant = definition and definition.variants[probe.variant]
  t.is_true(variant ~= nil, "observed implement probe must select a catalog variant")
  t.eq(#probe.from_states, #variant.source_states, "catalog source-state count comes from probe signature")
  for index, source_state in ipairs(probe.from_states) do
    t.eq(variant.source_states[index], source_state, "catalog source state comes from probe signature")
  end
  t.eq(variant.target_state, probe.to_state, "catalog target state comes from probe signature")

  local handoff = nil
  if #handoff_checks > 0 then
    handoff = { status = handoff_checks[#handoff_checks].state ~= nil and "valid" or "invalid" }
  end
  return {
    current = probe.current,
    variant = probe.variant,
    incoming_version = probe.incoming_version,
    target_version = probe.target_version,
    phase = probe.phase,
    retry = probe.retry,
    handoff = handoff,
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

local function decision_after_probe(decisions, probe, boundary_calls)
  local boundary_sequence = boundary_calls[1] and boundary_calls[1].sequence or math.huge
  for _, decision in ipairs(decisions) do
    if decision.sequence > probe.sequence
      and decision.sequence < boundary_sequence
      and decision.dept == "implement"
      and decision.to_state == "implementing" then
      return decision
    end
  end
  return nil
end

local function observed_admission(probe, decision, handoff_checks, boundary_reached)
  if boundary_reached then
    if probe.outcome == "pending" then
      local handoff = handoff_checks[#handoff_checks]
      t.is_true(handoff ~= nil and handoff.state ~= nil, "pending probe reaches boundary only through verified handoff")
      return { status = "apply", reason_code = "verified-own-ready-hand-off" }
    end
    t.eq(probe.outcome, "apply", "implement admission boundary requires applying CAS")
    return { status = "apply", reason_code = "apply" }
  end
  if probe.outcome == "pending" then
    return { status = "pending", reason_code = "source-marker-not-visible" }
  end
  if probe.outcome == "idempotent" then
    return { status = "idempotent", reason_code = "already-at-target" }
  end
  if probe.outcome == "stale" then
    local outcome = tostring(decision and decision.outcome or "")
    if outcome:find("incoming version < current marker version", 1, true) ~= nil then
      return { status = "stale", reason_code = "incoming-version-older" }
    end
    return { status = "stale", reason_code = "advanced-or-diverged" }
  end
  error("implement CAS probe applied without reaching the admission boundary")
end

local function post_admission_disposition(boundary_calls)
  if #boundary_calls == 0 then
    return "not-admitted"
  end
  local boundary = boundary_calls[1]
  if not boundary.allowed and boundary.reason == "wip-cap-reached" then
    return "wip-deferred"
  end
  return "admitted-past-wip"
end

local function render_comment(body)
  return string.format(
    '{"body":"%s","author":{"login":"fkst-test-bot"},"createdAt":"2026-06-03T01:00:00Z"}',
    tostring(body or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
  )
end

local function mock_wip_stop()
  t.mock_command('printf %s "$FKST_DEVLOOP_MAX_INFLIGHT"', {
    stdout = "1", stderr = "", exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = "dev", stderr = "", exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = INTEGRATION_BRANCH, stderr = "", exit_code = 0,
  })
  t.mock_command(core.gh_issue_list_wip_cmd(REPO), {
    stdout = '[{"number":' .. tostring(WIP_ISSUE_NUMBER) .. '}]\n', stderr = "", exit_code = 0,
  })
  local holder_proposal = "github-devloop/issue/owner/repo/" .. tostring(WIP_ISSUE_NUMBER)
  local holder_version = "ready/consensus-github-devloop/issue/owner/repo/51/2026-06-03T01-02-03Z"
  t.mock_command(core.gh_issue_view_state_cmd(REPO, WIP_ISSUE_NUMBER), {
    stdout = string.format(
      '{"title":"WIP","state":"OPEN","labels":[{"name":"fkst-dev:implementing"}],"comments":[%s],"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
      render_comment(core.state_marker(holder_proposal, "implementing", holder_version))
    ),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_wip_allow()
  t.mock_command('printf %s "$FKST_DEVLOOP_MAX_INFLIGHT"', {
    stdout = "1", stderr = "", exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', {
    stdout = "dev", stderr = "", exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', {
    stdout = INTEGRATION_BRANCH, stderr = "", exit_code = 0,
  })
  t.mock_command(core.gh_issue_list_wip_cmd(REPO), {
    stdout = "[]\n", stderr = "", exit_code = 0,
  })
end

local function make_event(fixture)
  local event = h.ready({ dedup_key = fixture.event_version or V_EQUAL })
  if fixture.impl_retry_attempt ~= nil then
    event.impl_retry_attempt = fixture.impl_retry_attempt
  end
  if fixture.handoff_visible_version ~= nil then
    event.ready_hand_off = {
      kind = "own-state-marker",
      proposal_id = event.proposal_id,
      state = "ready",
      marker_version = event.dedup_key,
      event_version = event.dedup_key,
      stage_rank = core.stage_rank("ready"),
      effects = "result-marker,ready-label,devloop-ready",
      comment_id = "IC_implement_cas_handoff",
    }
  end
  if fixture.blocked_version ~= nil then
    event.operator_reentry = {
      command = "reimplement",
      from_state = "blocked",
      pr_number = 7,
      state_version = fixture.blocked_version,
      impl_version = event.dedup_key,
    }
  end
  return event
end

local function fixture_comments(fixture, event)
  local comments = {}
  if fixture.current_state ~= nil then
    table.insert(comments, core.state_marker(PROPOSAL_ID, fixture.current_state, fixture.current_version))
  end
  if fixture.impl_failure then
    table.insert(comments, core.impl_failure_marker(PROPOSAL_ID, event.dedup_key, "codex-failed", 1))
  end
  if fixture.blocked_version ~= nil or fixture.current_target_link then
    table.insert(comments, m_builders.pr_link_marker(
      PROPOSAL_ID,
      7,
      "devloop-owner-repo-42-01HY",
      event.dedup_key,
      "dev"
    ))
  end
  return comments
end

local function mock_case(fixture, event)
  h.mock_bot_env()
  h.mock_write_env("")
  t.mock_command("gh api graphql", {
    stdout = '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}\n',
    stderr = "",
    exit_code = 0,
  })
  h.mock_issue_implement_raw(
    { "fkst-dev:" .. tostring(fixture.current_state or "ready") },
    fixture_comments(fixture, event)
  )
  if fixture.capture_activation then
    h.mock_issue_implement_raw(
      { "fkst-dev:" .. tostring(fixture.current_state or "ready") },
      fixture_comments(fixture, event)
    )
    mock_wip_allow()
    h.mock_fresh_implement_worktree()
  elseif not fixture.trace_capture then
    mock_wip_stop()
  end
  if fixture.handoff_visible_version ~= nil then
    local visible_marker = core.state_marker(PROPOSAL_ID, "ready", fixture.handoff_visible_version)
    t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/IC_implement_cas_handoff'", {
      stdout = '{"body":"' .. h.json_string(visible_marker) .. '","user":{"login":"fkst-test-bot"}}\n',
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
  local ok, failure = pcall(implement_department.pipeline, {
    queue = "devloop_ready",
    payload = event,
  })
  raise = original_raise
  return {
    exit_code = ok and 0 or 1,
    error = ok and nil or tostring(failure),
    raises = raises,
  }
end

local function assert_bidirectional(actual, expected, field, context)
  t.eq(actual[field], expected[field], context .. ": shadow-to-production " .. field)
  t.eq(expected[field], actual[field], context .. ": production-to-shadow " .. field)
end

local function assert_shadow_case(fixture, probe, evidence, observed, decision)
  local sealed_snapshot = restart_authority.seal_snapshot({
    owner = OWNER,
    proposal_id = PROPOSAL_ID,
    current = {
      state = fixture.current_state,
      version = fixture.current_version,
    },
  })
  local shadow, shadow_evidence = observe_shadow(function()
    return restart_authority.decide_transition(sealed_snapshot, {
      semantic_variant = fixture.semantic_variant,
      source_boundary = fixture.source_boundary,
      target = "implementing",
      incoming_version = evidence.incoming_version,
      target_version = evidence.target_version,
      phase = evidence.phase,
      retry = evidence.retry,
      handoff = evidence.handoff,
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
  t.eq(shadow.edge_id, fixture.edge_id, fixture.name .. ": selected edge")
  t.eq(shadow.cas_policy_id, POLICY_ID, fixture.name .. ": selected CAS policy")
  t.eq(shadow.grant, nil, fixture.name .. ": grant disabled")
  t.eq(shadow_evidence.current.state, fixture.current_state, fixture.name .. ": evidence current state")
  t.eq(shadow_evidence.current.version, fixture.current_version, fixture.name .. ": evidence raw current version")
  t.eq(shadow_evidence.variant, probe.variant, fixture.name .. ": evidence variant")
  t.eq(shadow_evidence.incoming_version, probe.incoming_version, fixture.name .. ": evidence incoming version")
  t.eq(shadow_evidence.target_version, probe.target_version, fixture.name .. ": evidence target version")
  t.eq(shadow_evidence.phase, evidence.phase, fixture.name .. ": evidence phase")
  t.eq(shadow_evidence.retry, evidence.retry, fixture.name .. ": evidence retry")
  t.eq(shadow_evidence.handoff, evidence.handoff, fixture.name .. ": evidence handoff")
end

local function assert_case(fixture)
  local event = make_event(fixture)
  mock_case(fixture, event)
  local result, named_calls, probes, decisions, handoff_checks, boundary_calls = observe_department(function()
    return run_real_department(event)
  end)

  local admission_phase = #probes == 0 and "pre-cas" or "cas"
  t.eq(admission_phase, fixture.admission_phase or "cas", fixture.name .. ": admission phase")
  t.eq(#named_calls, #probes, fixture.name .. ": named wrapper and exact probe counts agree")
  t.eq(#probes, admission_phase == "cas" and 1 or 0, fixture.name .. ": exact CAS probe count")
  t.eq(#boundary_calls, fixture.boundary_reached and 1 or 0, fixture.name .. ": WIP admission boundary reach")

  if admission_phase == "cas" then
    local probe = probes[1]
    t.is_true(probe.named_call ~= nil, fixture.name .. ": exact probe is nested under named production function")
    t.eq(probe.named_call.current, probe.current, fixture.name .. ": wrapper current is exact probe current")
    t.eq(probe.to_state, "implementing", fixture.name .. ": exact probe target")
    local evidence = evidence_from_probe(probe, handoff_checks)
    t.eq(evidence.current, probe.current, fixture.name .. ": catalog current comes from probe")
    t.eq(evidence.incoming_version, probe.incoming_version, fixture.name .. ": catalog incoming version comes from probe")
    t.eq(evidence.target_version, probe.target_version, fixture.name .. ": catalog target version comes from probe")
    if fixture.probe_incoming_differs_from_event then
      t.is_true(
        tostring(probe.incoming_version) ~= tostring(event.dedup_key),
        fixture.name .. ": production-derived probe version differs from raw event"
      )
    end

    local decision = decision_after_probe(decisions, probe, boundary_calls)
    t.is_true(decision ~= nil, fixture.name .. ": legacy CAS decision captured separately")
    local observed = observed_admission(probe, decision, handoff_checks, #boundary_calls == 1)
    local actual = catalog.resolve(POLICY_ID, evidence, projection)
    t.eq(actual.status, observed.status, fixture.name .. ": admission status parity")
    t.eq(actual.reason_code, observed.reason_code, fixture.name .. ": admission reason parity")
    if fixture.admission_status ~= nil then
      t.eq(observed.status, fixture.admission_status, fixture.name .. ": observed admission status")
      t.eq(actual.status, fixture.admission_status, fixture.name .. ": catalog admission status")
    end
    if fixture.legacy_log_outcome ~= nil then
      t.eq(decision.outcome, fixture.legacy_log_outcome, fixture.name .. ": legacy log outcome")
    end
    if fixture.semantic_variant ~= nil then
      assert_shadow_case(fixture, probe, evidence, observed, decision)
    end
  else
    t.eq(#boundary_calls, 0, fixture.name .. ": pre-CAS input cannot reach admission boundary")
  end

  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.name .. ": department exit code")
  t.eq(#result.raises, fixture.effect_count or 0, fixture.name .. ": captured effects")
  t.eq(
    post_admission_disposition(boundary_calls),
    fixture.post_admission_disposition or "not-admitted",
    fixture.name .. ": post-admission disposition"
  )
end

local function assert_malformed_fail_closed()
  local payload = h.ready()
  payload.dedup_key = 42
  local result, named_calls, probes, _, _, boundary_calls = observe_department(function()
    return run_real_department(payload)
  end)
  t.eq(result.exit_code, 0, "malformed payload exits through the production pre-CAS guard")
  t.eq(#named_calls, 0, "malformed payload does not call the named CAS function")
  t.eq(#probes, 0, "malformed payload does not reach an exact CAS probe")
  t.eq(#boundary_calls, 0, "malformed payload does not reach the admission boundary")
  local resolved = catalog.resolve(POLICY_ID, {
    current = { state = "ready", version = V_EQUAL },
    variant = "ready_to_implementing",
    incoming_version = payload.dedup_key,
    phase = "initial",
    retry = false,
  }, projection)
  t.eq(resolved.status, "illegal", "catalog rejects the same malformed version value")
  t.eq(resolved.reason_code, "invalid-evidence", "catalog malformed reason")
  t.eq(resolved.cas_outcome, "illegal(invalid-evidence)", "catalog malformed fail-closed outcome")
end

local TRACE_EDGE_ID = OWNER .. "/ready/entry/implementation_kicked_off"
local TRACE_FIXTURES = {
  { fixture_id = "newer-source-marker-missing-pending", current_state = nil,
    current_version = nil, event_version = V_NEWER, expected_exit_code = 1 },
  { fixture_id = "source-equal-apply", current_state = "ready",
    current_version = V_EQUAL, event_version = V_EQUAL, boundary_reached = true,
    capture_activation = true },
  { fixture_id = "source-older-stale", current_state = "ready",
    current_version = V_EQUAL, event_version = V_OLDER },
  { fixture_id = "target-idempotent", current_state = "impl-failed",
    current_version = V_EQUAL, event_version = V_EQUAL },
}

local function trace_artifact(corpus_hash, fixtures)
  return observation_support.admission_trace_artifact(
    "restart-implement-activation-trace.v1", OWNER, "implement-activation", corpus_hash, fixtures
  )
end

local function capture_trace_production(fixture)
  fixture.trace_capture = true
  local event = make_event(fixture)
  mock_case(fixture, event)
  local result, _, probes, decisions, handoffs, boundaries, serializers = observe_department(
    function() return run_real_department(event) end,
    { stop_after_activation = fixture.capture_activation }
  )
  local captured
  if #probes == 0 then
    local decision = decisions[1]
    t.eq(decision.outcome, "skip-idempotent(already at to_state)",
      fixture.fixture_id .. ": OLD pre-CAS idempotent")
    captured = {
      current = decision.current, incoming_version = event.dedup_key, phase = "initial", retry = false,
      status = "idempotent", reason_code = "already-at-target", cas_outcome = decision.outcome,
    }
  else
    local probe = probes[1]
    local decision = decision_after_probe(decisions, probe, boundaries)
    t.is_true(decision ~= nil, fixture.fixture_id .. ": OLD CAS decision")
    local evidence = evidence_from_probe(probe, handoffs)
    local observed = observed_admission(probe, decision, handoffs, fixture.boundary_reached == true)
    captured = {
      current = probe.current, incoming_version = probe.incoming_version,
      target_version = probe.target_version, phase = evidence.phase, retry = evidence.retry,
      handoff = evidence.handoff, status = observed.status, reason_code = observed.reason_code,
      cas_outcome = decision.outcome,
    }
  end
  t.eq(result.exit_code, fixture.expected_exit_code or 0, fixture.fixture_id .. ": OLD exit code")
  local write_count = #serializers.comment + #serializers.label
  t.eq(#result.raises, write_count, fixture.fixture_id .. ": OLD writes use observed serializers")
  local expected_serializer_calls = captured.status == "apply" and 1 or 0
  t.eq(#serializers.comment, expected_serializer_calls,
    fixture.fixture_id .. ": OLD comment serializer calls")
  t.eq(#serializers.label, expected_serializer_calls,
    fixture.fixture_id .. ": OLD label serializer calls")
  captured.result = result
  captured.serializers = serializers
  return captured
end

local function decide_new_trace(fixture, old)
  local snapshot = restart_effects.seal_snapshot({
    owner = OWNER, entity = { kind = "issue", repo = REPO, number = ISSUE_NUMBER },
    proposal_id = PROPOSAL_ID, current = old.current,
    snapshot_fingerprint = "r9-implement-activation:" .. fixture.fixture_id,
    lock_epoch = "r9-implement-activation:lock", generation = "r9-implement-activation:generation",
  })
  local decided = restart_effects.decide_transition(snapshot, {
    semantic_variant = "implementation_kicked_off", target = "implementing",
    incoming_version = old.incoming_version, target_version = old.target_version,
    phase = old.phase, retry = old.retry, handoff = old.handoff,
  })
  local writes = json_array()
  if decided.status == "apply" then
    local grant = restart_effects.mint_grant(snapshot, decided, "comment:issue:implementation-start")
    t.is_true(grant ~= nil, fixture.fixture_id .. ": NEW grant minted")
    local facade = restart_effect_facade.make({ family = "implement-activation",
      verify_grant = restart_effects.verify_grant,
      sink_inventory = require("core.restart.sink_inventory") })
    for ordinal, effect_id in ipairs(decided.granted_effect_ids) do
      local emitted = facade.emit(grant, effect_id, snapshot, old.serializers.comment[1])
      t.is_true(emitted ~= nil, fixture.fixture_id .. ": NEW facade emitted " .. effect_id)
      table.insert(writes, observation_support.admission_trace_write(ordinal, effect_id, emitted))
    end
  end
  return decided, writes
end

local function assert_implement_activation_trace_equality()
  local corpus = json.decode(file.read(IMPLEMENT_ACTIVATION_CORPUS_PATH))
  local old_fixtures, new_fixtures = json_array(), json_array()
  for _, fixture in ipairs(TRACE_FIXTURES) do
    local old = capture_trace_production(fixture)
    local decided, new_writes = decide_new_trace(fixture, old)
    local old_writes = old.status == "apply"
      and observation_support.admission_trace_writes(old.result.raises) or json_array()
    table.insert(old_fixtures, observation_support.admission_trace_fixture(fixture, TRACE_EDGE_ID,
      old.status, old.reason_code, old.cas_outcome, decided.effect_entitlement_id,
      decided.granted_effect_ids, old_writes))
    table.insert(new_fixtures, observation_support.admission_trace_fixture(fixture, TRACE_EDGE_ID,
      decided.status, decided.reason_code, decided.cas_outcome, decided.effect_entitlement_id,
      decided.granted_effect_ids, new_writes))
  end
  local old_trace = trace_artifact(corpus.artifact_sha256, old_fixtures)
  local new_trace = trace_artifact(corpus.artifact_sha256, new_fixtures)
  t.eq(canonical_json(old_trace), canonical_json(new_trace),
    "R9 implement-activation OLD and NEW semantic trace")
  local mkdir_ok = os.execute("mkdir -p .fkst/run")
  if mkdir_ok ~= true and mkdir_ok ~= 0 then
    error("R9 implement-activation trace could not create its artifact directory", 0)
  end
  file.write(IMPLEMENT_ACTIVATION_NEW_TRACE_PATH, canonical_json(new_trace) .. "\n")
  t.eq(canonical_json(old_trace), canonical_json(observation_support.admission_trace_active_projection(corpus)),
    "R9 implement-activation OLD observation corpus")
  t.eq(canonical_json(new_trace), canonical_json(observation_support.admission_trace_active_projection(corpus)),
    "R9 implement-activation NEW semantic trace")
end

return {
  test_ready_source_equal_reaches_admission_boundary = function()
    assert_case({
      name = "ready-source-equal",
      current_state = "ready",
      current_version = V_EQUAL,
      event_version = V_EQUAL,
      boundary_reached = true,
      admission_status = "apply",
      legacy_log_outcome = "applied",
      post_admission_disposition = "wip-deferred",
      semantic_variant = "implementation_kicked_off",
      edge_id = OWNER .. "/ready/entry/implementation_kicked_off",
    })
  end,

  test_ready_source_older_event_is_stale = function()
    assert_case({
      name = "ready-source-older",
      current_state = "ready",
      current_version = V_EQUAL,
      event_version = V_OLDER,
      admission_status = "stale",
      legacy_log_outcome = "skip-stale(incoming version < current marker version)",
    })
  end,

  test_earlier_state_with_newer_event_is_pending = function()
    assert_case({
      name = "thinking-source-newer",
      current_state = "thinking",
      current_version = V_EQUAL,
      event_version = V_NEWER,
      admission_status = "pending",
      expected_exit_code = 1,
      legacy_log_outcome = "retry-pending(from-state marker not yet visible)",
    })
  end,

  test_unrelated_current_state_is_stale = function()
    assert_case({
      name = "blocked-unrelated-stale",
      current_state = "blocked",
      current_version = V_EQUAL,
      event_version = V_EQUAL,
      admission_status = "stale",
      legacy_log_outcome = "skip-advanced-or-diverged",
    })
  end,

  test_ordering_equal_raw_different_versions_use_observed_probe_evidence = function()
    t.is_true(
      V_ORDERING_EQUAL_CURRENT ~= V_ORDERING_EQUAL_INCOMING,
      "ordering-equal fixture versions must be byte-different"
    )
    assert_case({
      name = "ready-ordering-equal-raw-different",
      current_state = "ready",
      current_version = V_ORDERING_EQUAL_CURRENT,
      event_version = V_ORDERING_EQUAL_INCOMING,
      boundary_reached = true,
      admission_status = "apply",
      legacy_log_outcome = "applied",
      post_admission_disposition = "wip-deferred",
    })
  end,

  test_valid_direct_id_handoff_overlays_pending_probe_to_apply = function()
    assert_case({
      name = "verified-ready-handoff",
      current_state = nil,
      current_version = nil,
      event_version = V_EQUAL,
      handoff_visible_version = V_EQUAL,
      boundary_reached = true,
      admission_status = "apply",
      legacy_log_outcome = "apply(verified-own-ready-hand-off)",
      post_admission_disposition = "wip-deferred",
    })
  end,

  test_direct_id_handoff_raw_version_mismatch_remains_pending = function()
    assert_case({
      name = "ready-handoff-version-mismatch",
      current_state = nil,
      current_version = nil,
      event_version = V_EQUAL,
      handoff_visible_version = V_OLDER,
      admission_status = "pending",
      expected_exit_code = 1,
      legacy_log_outcome = "retry-pending(from-state marker not yet visible)",
    })
  end,

  test_impl_failed_retry_variant_applies_with_derived_attempt_version = function()
    assert_case({
      name = "impl-failed-retry",
      current_state = "impl-failed",
      current_version = V_EQUAL,
      event_version = V_EQUAL,
      impl_retry_attempt = 2,
      impl_failure = true,
      boundary_reached = true,
      admission_status = "apply",
      post_admission_disposition = "wip-deferred",
      semantic_variant = "retry-implementation",
      edge_id = OWNER .. "/impl-failed/entry/retry-implementation",
    })
  end,

  test_blocked_reentry_variant_uses_spied_cyclic_versions = function()
    local blocked_version = V_EQUAL .. "/review-loop/3"
    assert_case({
      name = "blocked-operator-reentry",
      current_state = "blocked",
      current_version = blocked_version,
      blocked_version = blocked_version,
      event_version = V_EQUAL,
      impl_retry_attempt = 2,
      boundary_reached = true,
      admission_status = "apply",
      probe_incoming_differs_from_event = true,
      post_admission_disposition = "wip-deferred",
      semantic_variant = "reimplement_blocked_open_pr",
      source_boundary = "open-pr",
      edge_id = OWNER .. "/implementing/operator_reentry/reimplement_blocked_open_pr",
    })
  end,

  test_current_target_is_classified_as_pre_cas = function()
    assert_case({
      name = "implementing-target-pre-cas",
      current_state = "implementing",
      current_version = V_EQUAL,
      event_version = V_EQUAL,
      current_target_link = true,
      admission_phase = "pre-cas",
    })
  end,

  test_malformed_version_fails_closed_before_cas_and_in_catalog = function()
    assert_malformed_fail_closed()
  end,

  test_r9_implement_activation_old_equals_new_normalized_trace = function()
    assert_implement_activation_trace_equality()
  end,
}
