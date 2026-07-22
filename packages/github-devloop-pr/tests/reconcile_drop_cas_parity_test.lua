local catalog = require("devloop.restart_cas_catalog")
local config = require("devloop.config")
local conv_attempts = require("devloop.convergence.attempts")
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_rae = require("devloop.restart_actionable_epoch")
local observation = require("testkit_internal.old_behavior_observation_support")
local owner_pending_projection = require("devloop.restart_owner_pending_projection")
local replay_fields = require("devloop.replay_fields")
local restart_authority = require("core.restart_authority")
local testing = require("testkit_internal.testing")
local reconcile_department = require("departments.reconcile.main")

local t = h.t
local core = h.core
local json_array = observation.json_array
local OWNER = core.restart_package_name
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local HEAD_SHA = "def456"
local NOW_SECONDS = 1784048400
local OLD_CREATED_AT = "2026-06-03T01:00:00Z"

local inventories = {
  canonicalization = require("core.restart.canonicalization_inventory"),
  entry = require("core.restart.entry_inventory"),
  operator_reentry = require("core.restart.operator_reentry_inventory"),
}
local projection = owner_pending_projection.derive(OWNER, core.restart_transition_table(), inventories)

local TIMEOUT_SOURCES = {
  fixing = { variant = "fixing_to_blocked", edge = "fixing/entry/watchdog_reconcile_terminal" },
  ["merge-ready"] = { variant = "merge_ready_to_blocked", edge = "merge-ready/timeout/merge_gate/watchdog_reconcile_terminal" },
  merging = { variant = "merging_to_blocked", edge = "merging/entry/watchdog_reconcile_terminal" },
  ["pr-open"] = { variant = "pr_open_to_blocked", edge = "pr-open/entry/watchdog_reconcile_terminal" },
  ["review-meta"] = { variant = "review_meta_to_blocked", edge = "review-meta/entry/watchdog_reconcile_terminal" },
  reviewing = { variant = "reviewing_to_blocked", edge = "reviewing/timeout/watchdog_reconcile_terminal" },
}

local function restart_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function assert_owner_apply(probe, proposal_id, intent, edge_id, policy_id)
  local sealed = restart_authority.seal_snapshot({
    owner = OWNER,
    proposal_id = proposal_id,
    current = probe.current,
  })
  local decision = restart_authority.decide_transition(sealed, intent)
  t.eq(decision.status, "apply", edge_id .. ": owner apply")
  t.eq(decision.cas_outcome, "applied", edge_id .. ": owner CAS outcome")
  t.eq(decision.edge_id, edge_id, edge_id .. ": selected edge")
  t.eq(decision.cas_policy_id, policy_id, edge_id .. ": selected policy")
  t.eq(decision.grant, nil, edge_id .. ": shadow remains grant-disabled")
end

local function trusted_comment(body)
  return { body = body, author_login = "fkst-test-bot", created_at = OLD_CREATED_AT }
end

local function prepare_pr(comments)
  h.mock_bot_env()
  h.mock_default_issue_claim(REPO, ISSUE_NUMBER)
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = REPO,
    number = PR_NUMBER,
    comments = comments,
    head = "devloop-owner-repo-42-01HY",
    head_sha = HEAD_SHA,
    state = "OPEN",
    base_branch = "dev",
    labels = {},
  }, entity_read_mocks.pr_origin_selector, 1)
end

local function observe_real_department(event, comments, from_state)
  prepare_pr(comments)
  return observation.observe_department({
    config = config,
    devloop_logging = devloop_logging,
    devloop_state = devloop_state,
    dept = "reconcile",
    from_state = from_state,
    transition_kind = "versioned_transition_status",
    run = function()
      local original_now = now
      now = function() return NOW_SECONDS end
      local ok, result = pcall(testing.run_fake, reconcile_department, event)
      now = original_now
      if not ok then error(result, 0) end
      return result
    end,
    codex_runs_for_read = json_array(),
    write_mode = "real",
  })
end

local function with_no_codex_runs(fn)
  local original = fkst.codex_runs
  fkst.codex_runs = function()
    return { running = json_array(), recent = json_array() }
  end
  local ok, result = pcall(fn)
  fkst.codex_runs = original
  if not ok then error(result, 0) end
  return result
end

local function add_fixing_attempts(event, comments)
  local row = restart_row("fixing")
  local state = {
    state = "fixing",
    version = event.payload.issue_version,
    marker_created_at = OLD_CREATED_AT,
    proposal_id = event.payload.proposal_id,
  }
  local facts = {
    proposal_id = event.payload.proposal_id,
    current = { comments = comments },
    current_pr = { head_sha = HEAD_SHA, comments = comments },
    source_ref = event.payload.source_ref,
    head_sha = HEAD_SHA,
    fresh_current_state = state,
  }
  local eval = with_no_codex_runs(function()
    return m_rae.actionable_epoch_resolve(core, row, state, facts, NOW_SECONDS)
  end)
  t.eq(eval.status, "actionable", "fixing timeout fixture is actionable")
  for round = 1, 2 do
    table.insert(comments, trusted_comment(conv_attempts.timeout_attempt_v2_marker(
      event.payload.proposal_id,
      row.from_state,
      row.liveness_class_id,
      eval.generation_key,
      round,
      event.payload.source_ref
    )))
  end
end

local function timeout_probe(source_state)
  local seed = h.fix_reconcile()
  local state_version = seed.issue_version .. "/timeout/" .. source_state .. "/3"
  local payload = conv_reconcile.build_devloop_timeout_reconcile_payload(
    restart_row(source_state),
    { state = source_state, version = state_version },
    seed.proposal_id,
    entity_lib.pr_source_ref(REPO, PR_NUMBER),
    3
  )
  local event = { queue = "devloop_timeout_reconcile", payload = payload, now_seconds = NOW_SECONDS }
  local comments = json_array({
    trusted_comment(core.state_marker(payload.proposal_id, source_state, state_version)),
  })
  if source_state == "fixing" then add_fixing_attempts(event, comments) end
  local _, captured = observe_real_department(event, comments, source_state)
  t.eq(#captured.probes, 1, source_state .. ": real timeout reconcile CAS probe")
  local probe = captured.probes[1]
  t.eq(probe.outcome, "apply", source_state .. ": real timeout reconcile apply")
  t.eq(
    probe.incoming_version,
    conv_reconcile.timeout_reconcile_state_version(state_version, source_state, 3),
    source_state .. ": real timeout reconcile version form"
  )
  return probe, payload.proposal_id
end

local function review_probe()
  local payload = h.review_reconcile()
  local event = { queue = "devloop_review_reconcile", payload = payload, now_seconds = NOW_SECONDS }
  local comments = json_array({
    trusted_comment(core.state_marker(payload.proposal_id, "reviewing", payload.issue_version)),
  })
  local _, captured = observe_real_department(event, comments, "reviewing")
  t.eq(#captured.probes, 1, "real review reconcile CAS probe")
  local probe = captured.probes[1]
  t.eq(probe.outcome, "apply", "real review reconcile apply")
  t.eq(
    probe.incoming_version,
    conv_reconcile.review_reconcile_terminal_state_version(payload.issue_version, payload.round),
    "real review reconcile version form"
  )
  return probe, payload.proposal_id
end

local function assert_bidirectional(actual, expected, context)
  t.eq(actual, expected, context .. ": shadow-to-old")
  t.eq(expected, actual, context .. ": old-to-shadow")
end

local function assert_matrix(probe, policy_id, variant, context)
  t.eq(#probe.from_states, 1, context .. ": singleton real source set")
  t.eq(probe.to_state, "blocked", context .. ": real target")
  t.eq(probe.target_version, nil, context .. ": versioned base has no target version")
  local cases = {
    { name = "apply", current = probe.current, reason = "apply" },
    { name = "idempotent", current = { state = "blocked", version = probe.incoming_version }, reason = "already-at-target" },
    { name = "stale", current = { state = "merged", version = probe.incoming_version }, reason = "advanced-or-diverged" },
  }
  for _, fixture in ipairs(cases) do
    local old_status = devloop_state.versioned_transition_status(
      fixture.current,
      probe.from_states,
      probe.to_state,
      probe.incoming_version
    )
    local old_cas_outcome = devloop_state.cas_outcome(fixture.current, old_status, probe.incoming_version)
    local shadow = catalog.resolve(policy_id, {
      current = fixture.current,
      variant = variant,
      incoming_version = probe.incoming_version,
    }, projection)
    local case_context = context .. "/" .. fixture.name
    assert_bidirectional(shadow.status, old_status, case_context .. ": status")
    assert_bidirectional(shadow.cas_outcome, old_cas_outcome, case_context .. ": CAS outcome")
    t.eq(shadow.reason_code, fixture.reason, case_context .. ": reason code")
  end
end

return {
  test_review_reconcile_drop_reuses_real_old_versioned_policy = function()
    local probe, proposal_id = review_probe()
    assert_matrix(probe, "cas.legacy_issue_reconcile_v1", "reviewing_to_blocked", "review-reconcile")
    assert_owner_apply(probe, proposal_id, {
      semantic_variant = "review_reconcile_true_stall",
      source_boundary = "devloop_review_reconcile",
      target = "blocked",
      incoming_version = probe.incoming_version,
    }, OWNER .. "/reviewing/entry/review_reconcile_true_stall", "cas.legacy_issue_reconcile_v1")
  end,

  test_pr_timeout_reconcile_drop_reuses_real_old_versioned_policy = function()
    for source_state, expected in pairs(TIMEOUT_SOURCES) do
      local probe, proposal_id = timeout_probe(source_state)
      assert_matrix(
        probe,
        "cas.legacy_timeout_reconcile_v1",
        expected.variant,
        "pr-timeout-reconcile/" .. source_state
      )
      assert_owner_apply(probe, proposal_id, {
        semantic_variant = "watchdog_reconcile_terminal",
        target = "blocked",
        incoming_version = probe.incoming_version,
      }, OWNER .. "/" .. expected.edge, "cas.legacy_timeout_reconcile_v1")
    end
  end,
}
