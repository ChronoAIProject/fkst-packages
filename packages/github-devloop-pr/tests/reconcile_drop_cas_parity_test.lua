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
local restart_effect_facade = require("core.restart_effect_facade")
local restart_effects = require("core.restart_effects")
local testing = require("testkit_internal.testing")
local reconcile_department = require("departments.reconcile.main")

local t = h.t
local core = h.core
local canonical_json = observation.canonical_json
local json_array = observation.json_array
local OWNER = core.restart_package_name
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local HEAD_SHA = "def456"
local NOW_SECONDS = 1784048400
local OLD_CREATED_AT = "2026-06-03T01:00:00Z"
local INVENTORY_PATH = "migration/restart-lifecycle.inventory.json"
local REVIEW_SITE = {
  path = "packages/github-devloop-pr/departments/reconcile/main.lua",
  symbol = "pipeline_review",
  ordinal = "versioned_transition_status:reviewing->blocked",
}

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
  t.eq(decision.grant, nil, edge_id .. ": authority does not mint grants")
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

local function observe_timeout_department(event, comments, from_state)
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
  local _, captured = observe_timeout_department(event, comments, source_state)
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

local function assert_bidirectional(actual, expected, context)
  t.eq(actual, expected, context .. ": shadow-to-old")
  t.eq(expected, actual, context .. ": old-to-shadow")
end

local function assert_timeout_matrix(probe, policy_id, variant, context)
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

local function is_review_record(record)
  local site = type(record) == "table" and record.site or nil
  return type(site) == "table"
    and site.path == REVIEW_SITE.path
    and site.symbol == REVIEW_SITE.symbol
    and site.ordinal == REVIEW_SITE.ordinal
end

local function frozen_review_records()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  local records = json_array()
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if is_review_record(record) then
      table.insert(records, record)
    end
  end
  table.sort(records, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  t.eq(#records, 4, "review reconcile frozen OLD observation count")
  return records
end

local function comments_for_review_record(record, payload)
  local reason_code = record.old_outcome.reason_code
  if reason_code == "apply" then
    return json_array({
      core.state_marker(payload.proposal_id, "reviewing", payload.issue_version),
    })
  end
  if reason_code == "already-terminal" then
    return json_array({
      core.state_marker(payload.proposal_id, "blocked", record.old_inputs.current_fact.version),
    })
  end
  if reason_code == "review-reconcile-marker-visible" then
    return json_array({
      core.build_review_reconcile_comment_request(
        REPO,
        tostring(ISSUE_NUMBER),
        payload,
        "drop",
        "already done",
        record.old_inputs.incoming_version
      ).body,
    })
  end
  if reason_code == "state-advanced" then
    return json_array({
      core.state_marker(
        payload.proposal_id,
        record.old_inputs.current_fact.state,
        record.old_inputs.current_fact.version
      ),
    })
  end
  error("unknown frozen review reconcile observation: " .. tostring(reason_code), 0)
end

local function expected_raises(record)
  local raises = json_array()
  for _, write in ipairs(record.old_outcome.observable_writes or {}) do
    table.insert(raises, { queue = write.queue, payload = write.payload })
  end
  return raises
end

local function normalized_raises(values)
  local raises = json_array()
  for _, raised in ipairs(values or {}) do
    table.insert(raises, { queue = raised.queue, payload = raised.payload })
  end
  return raises
end

local function run_review_production(record)
  local payload = h.review_reconcile()
  local event = {
    queue = "devloop_review_reconcile",
    payload = payload,
    now_seconds = NOW_SECONDS,
  }
  prepare_pr(comments_for_review_record(record, payload))

  local captured = {
    builder_comments = {},
    builder_labels = {},
    cas_decisions = {},
    facade_emits = {},
    facade_families = {},
    owner_decisions = {},
  }
  local original_versioned = devloop_state.versioned_transition_status
  local original_log_cas = devloop_logging.log_cas_decision
  local original_make = restart_effect_facade.make
  local original_decide = restart_effects.decide_transition
  local original_comment_builder = core.build_review_reconcile_comment_request
  local original_label_builder = core.build_review_reconcile_label_request

  devloop_state.versioned_transition_status = function()
    error("review reconcile production used retired direct CAS", 0)
  end
  devloop_logging.log_cas_decision = function(...)
    local args = { ... }
    table.insert(captured.cas_decisions, {
      dept = args[1],
      proposal_id = args[2],
      current = args[3],
      from_state = args[4],
      to_state = args[5],
      outcome = args[6],
      reason = args[7],
    })
    return original_log_cas(...)
  end
  restart_effects.decide_transition = function(snapshot, intent)
    local decision = original_decide(snapshot, intent)
    table.insert(captured.owner_decisions, { intent = intent, decision = decision })
    return decision
  end
  restart_effect_facade.make = function(options)
    table.insert(captured.facade_families, options.family)
    local facade = original_make(options)
    local original_emit = facade.emit
    facade.emit = function(grant, effect_id, snapshot, args)
      local emitted, rejection = original_emit(grant, effect_id, snapshot, args)
      table.insert(captured.facade_emits, {
        effect_id = effect_id,
        payload = emitted,
        rejection = rejection,
      })
      return emitted, rejection
    end
    return facade
  end
  core.build_review_reconcile_comment_request = function(...)
    local request = original_comment_builder(...)
    table.insert(captured.builder_comments, request)
    return request
  end
  core.build_review_reconcile_label_request = function(...)
    local request = original_label_builder(...)
    table.insert(captured.builder_labels, request)
    return request
  end

  local ok, result = pcall(testing.run_fake, reconcile_department, event)

  core.build_review_reconcile_label_request = original_label_builder
  core.build_review_reconcile_comment_request = original_comment_builder
  restart_effect_facade.make = original_make
  restart_effects.decide_transition = original_decide
  devloop_logging.log_cas_decision = original_log_cas
  devloop_state.versioned_transition_status = original_versioned

  if not ok then error(result, 0) end
  return result, captured, payload
end

local function assert_review_owner_matrix(records)
  local expected_status = {
    apply = "apply",
    ["already-terminal"] = "idempotent",
    ["review-reconcile-marker-visible"] = "idempotent",
    ["state-advanced"] = "stale",
  }
  for _, record in ipairs(records) do
    local current = record.old_inputs.current_fact
    local snapshot = restart_effects.seal_snapshot({
      owner = OWNER,
      entity = { kind = "pr", repo = REPO, number = PR_NUMBER },
      proposal_id = record.typed_intent.lineage.proposal_id,
      current = { state = current.state, version = current.version },
      snapshot_fingerprint = "r9-pr-review-reconcile|" .. record.old_outcome.reason_code,
      lock_epoch = "r9-pr-review-reconcile@" .. current.version,
      generation = current.version,
    })
    local decision = restart_effects.decide_transition(snapshot, {
      semantic_variant = "review_reconcile_true_stall",
      source_boundary = "devloop_review_reconcile",
      target = "blocked",
      incoming_version = record.old_inputs.incoming_version,
      target_version = nil,
      overlay_version = record.old_inputs.incoming_version,
    })
    local reason_code = record.old_outcome.reason_code
    t.eq(decision.status, expected_status[reason_code], reason_code .. ": owner status vs frozen OLD")
    t.eq(
      decision.edge_id,
      OWNER .. "/reviewing/entry/review_reconcile_true_stall",
      reason_code .. ": owner edge"
    )
    if decision.status == "apply" then
      t.eq(decision.cas_outcome, record.old_outcome.cas_outcome, reason_code .. ": owner CAS outcome")
      t.eq(#decision.granted_effect_ids, 2, reason_code .. ": owner granted effect count")
    else
      t.eq(#(decision.granted_effect_ids or {}), 0, reason_code .. ": no non-apply effects")
    end
  end
end

local function assert_review_production_equals_frozen_old()
  local records = frozen_review_records()
  assert_review_owner_matrix(records)
  for _, record in ipairs(records) do
    local result, captured = run_review_production(record)
    local reason_code = record.old_outcome.reason_code
    t.eq(type(result), "table", reason_code .. ": production result")
    t.eq(#captured.cas_decisions, 1, reason_code .. ": one production CAS disposition")
    t.eq(
      captured.cas_decisions[1].outcome,
      record.old_outcome.cas_outcome,
      reason_code .. ": production disposition equals frozen OLD"
    )
    t.eq(
      canonical_json(normalized_raises(result.raises)),
      canonical_json(expected_raises(record)),
      reason_code .. ": production full payloads are byte-exact with frozen OLD"
    )

    if reason_code == "apply" then
      t.eq(
        record.evidence_refs[1].ref,
        "devloop.state.versioned_transition_status:apply",
        "apply: frozen OLD was probed from the real retired CAS"
      )
      t.eq(#captured.owner_decisions, 1, "apply: production owner decision count")
      t.eq(captured.owner_decisions[1].decision.status, "apply", "apply: production owner decision")
      t.eq(#captured.facade_families, 1, "apply: production facade construction count")
      t.eq(captured.facade_families[1], "pr-review-reconcile", "apply: production facade family")
      t.eq(#captured.facade_emits, 2, "apply: production facade emit count")
      t.eq(#captured.builder_comments, 1, "apply: facade reused OLD comment builder")
      t.eq(#captured.builder_labels, 1, "apply: facade reused OLD label builder")
      t.eq(
        canonical_json(captured.builder_comments[1]),
        canonical_json(result.raises[1].payload),
        "apply: comment facade payload is the OLD builder payload"
      )
      t.eq(
        canonical_json(captured.builder_labels[1]),
        canonical_json(result.raises[2].payload),
        "apply: label facade payload is the OLD builder payload"
      )
    else
      t.eq(#captured.owner_decisions, 0, reason_code .. ": unchanged pre-CAS guard")
      t.eq(#captured.facade_families, 0, reason_code .. ": pre-CAS guard does not construct facade")
      t.eq(#captured.facade_emits, 0, reason_code .. ": pre-CAS guard emits no effect")
      t.eq(#captured.builder_comments, 0, reason_code .. ": pre-CAS guard calls no comment builder")
      t.eq(#captured.builder_labels, 0, reason_code .. ": pre-CAS guard calls no label builder")
    end
  end
end

return {
  test_review_reconcile_production_grant_facade_equals_frozen_old = function()
    assert_review_production_equals_frozen_old()
  end,

  test_pr_timeout_reconcile_drop_reuses_real_old_versioned_policy = function()
    for source_state, expected in pairs(TIMEOUT_SOURCES) do
      local probe, proposal_id = timeout_probe(source_state)
      assert_timeout_matrix(
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
