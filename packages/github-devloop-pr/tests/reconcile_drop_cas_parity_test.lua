local conv_attempts = require("devloop.convergence.attempts")
local conv_reconcile = require("devloop.convergence.reconcile")
local devloop_logging = require("devloop.logging")
local devloop_state = require("devloop.state")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local m_rae = require("devloop.restart_actionable_epoch")
local m_mgw = require("devloop.merge_gate_wait")
local observation = require("testkit_internal.old_behavior_observation_support")
local requests_labels = require("devloop.requests.labels")
local replay_fields = require("devloop.replay_fields")
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
}
local TIMEOUT_SITE = {
  path = "packages/github-devloop-pr/departments/reconcile/main.lua",
  symbol = "pipeline_timeout",
}
local RECENT_CREATED_AT = "2026-07-14T16:59:00Z"

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

local function trusted_comment(body, created_at)
  return { body = body, author_login = "fkst-test-bot", created_at = created_at or OLD_CREATED_AT }
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

local function is_review_record(record)
  local site = type(record) == "table" and record.site or nil
  return type(site) == "table"
    and site.path == REVIEW_SITE.path
    and site.symbol == REVIEW_SITE.symbol
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
  local original_log_cas = devloop_logging.log_cas_decision
  local original_make = restart_effect_facade.make
  local original_decide = restart_effects.decide_transition
  local original_comment_builder = core.build_review_reconcile_comment_request
  local original_label_builder = core.build_review_reconcile_label_request

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
        record.evidence_refs[1].kind,
        "runtime-cas-probe",
        "apply: frozen baseline retains protected probe evidence"
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

local function is_timeout_record(record)
  local site = type(record) == "table" and record.site or nil
  return type(site) == "table"
    and site.path == TIMEOUT_SITE.path
    and site.symbol == TIMEOUT_SITE.symbol
end

local function frozen_timeout_records()
  local inventory = json.decode(file.read(INVENTORY_PATH))
  local records = json_array()
  for _, record in ipairs(inventory.old_behavior_observations or {}) do
    if is_timeout_record(record) then table.insert(records, record) end
  end
  table.sort(records, function(left, right)
    return tostring(left.observation_id) < tostring(right.observation_id)
  end)
  t.eq(#records, 44, "timeout reconcile frozen OLD observation count")
  return records
end

local function timeout_source_state(record)
  return record.old_inputs.caller_from_states[1]
end

local function timeout_event_for_record(record)
  local lineage = record.typed_intent.lineage
  local source_state = timeout_source_state(record)
  local payload = conv_reconcile.build_devloop_timeout_reconcile_payload(
    restart_row(source_state),
    { state = source_state, version = lineage.issue_version },
    lineage.proposal_id,
    lineage.source_ref,
    lineage.round
  )
  return {
    queue = "devloop_timeout_reconcile",
    payload = payload,
    now_seconds = NOW_SECONDS,
  }
end

local function timeout_comments_for_record(record, event)
  local source_state = timeout_source_state(record)
  local current = record.old_inputs.current_fact
  local reason_code = record.old_outcome.reason_code
  if reason_code == "apply"
    or reason_code == "pr-surface-gone-fallback"
    or reason_code == "external-ci-wait-expired" then
    local comments = json_array({
      trusted_comment(core.state_marker(event.payload.proposal_id, source_state, event.payload.issue_version)),
    })
    if source_state == "fixing" then add_fixing_attempts(event, comments) end
    if reason_code == "external-ci-wait-expired" then
      table.insert(comments, trusted_comment(m_mgw.merge_gate_wait_marker(
        event.payload.proposal_id,
        PR_NUMBER,
        m_mgw.merge_gate_wait_version_lineage(event.payload.issue_version),
        HEAD_SHA,
        "ci-wait",
        "CI_WAIT"
      )))
    end
    return comments
  end
  if reason_code == "timeout-reconcile-marker-visible" then
    local terminal_version = record.old_inputs.incoming_version
    return json_array({
      trusted_comment(core.state_marker(event.payload.proposal_id, source_state, event.payload.issue_version)),
      trusted_comment(conv_reconcile.timeout_reconcile_marker(
        event.payload.proposal_id,
        event.payload.issue_version,
        source_state,
        event.payload.round,
        "drop",
        { terminal_version = terminal_version }
      )),
    })
  end
  local created_at = reason_code == "no-longer-over-budget" and RECENT_CREATED_AT or OLD_CREATED_AT
  return json_array({
    trusted_comment(core.state_marker(
      event.payload.proposal_id,
      current.state,
      current.version
    ), created_at),
  })
end

local function timeout_is_issue_fallback(record)
  return tostring(record.observation_id):find("-issue-fallback-apply/", 1, true) ~= nil
end

local function prepare_timeout_record(record, comments)
  if not timeout_is_issue_fallback(record) then
    prepare_pr(comments)
    return
  end
  h.mock_bot_env()
  h.mock_default_issue_claim(REPO, ISSUE_NUMBER)
  entity_read_mocks.mock_pr_view_raw_selector(t, {
    repo = REPO,
    number = PR_NUMBER,
  }, entity_read_mocks.pr_origin_selector, {
    stdout = "",
    stderr = "HTTP 404: Not Found",
    exit_code = 1,
  }, 1)
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = REPO,
    number = ISSUE_NUMBER,
    comments = comments,
    labels = {},
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    register_all_views = true,
    times = 1,
  })
end

local function run_timeout_production(record)
  local event = timeout_event_for_record(record)
  prepare_timeout_record(record, timeout_comments_for_record(record, event))
  local captured = {
    cas_decisions = {},
    facade_args = {},
    facade_emits = {},
    facade_families = {},
    issue_builders = {},
    label_builders = {},
    owner_decisions = {},
  }
  local original_log_cas = devloop_logging.log_cas_decision
  local original_make = restart_effect_facade.make
  local original_decide = restart_effects.decide_transition
  local original_issue_builder = conv_reconcile.build_timeout_reconcile_comment_request
  local original_label_builder = requests_labels.build_state_label_request

  devloop_logging.log_cas_decision = function(...)
    local args = { ... }
    table.insert(captured.cas_decisions, {
      current = args[3], from_state = args[4], to_state = args[5],
      outcome = args[6], reason = args[7],
    })
    return original_log_cas(...)
  end
  restart_effects.decide_transition = function(snapshot, intent)
    local decided = original_decide(snapshot, intent)
    table.insert(captured.owner_decisions, { intent = intent, decision = decided })
    return decided
  end
  restart_effect_facade.make = function(options)
    table.insert(captured.facade_families, options.family)
    local facade = original_make(options)
    local original_emit = facade.emit
    facade.emit = function(grant, effect_id, snapshot, args)
      local emitted, rejection = original_emit(grant, effect_id, snapshot, args)
      table.insert(captured.facade_args, args)
      table.insert(captured.facade_emits, {
        effect_id = effect_id, payload = emitted, rejection = rejection,
      })
      return emitted, rejection
    end
    return facade
  end
  conv_reconcile.build_timeout_reconcile_comment_request = function(...)
    local request = original_issue_builder(...)
    table.insert(captured.issue_builders, request)
    return request
  end
  requests_labels.build_state_label_request = function(...)
    local request = original_label_builder(...)
    table.insert(captured.label_builders, request)
    return request
  end

  local original_now = now
  now = function() return NOW_SECONDS end
  local ok, result = pcall(testing.run_fake, reconcile_department, event)
  now = original_now
  requests_labels.build_state_label_request = original_label_builder
  conv_reconcile.build_timeout_reconcile_comment_request = original_issue_builder
  restart_effect_facade.make = original_make
  restart_effects.decide_transition = original_decide
  devloop_logging.log_cas_decision = original_log_cas
  if not ok then error(result, 0) end
  return result, captured
end

local function assert_timeout_owner_matrix(records)
  local apply_by_source = {}
  for _, record in ipairs(records) do
    if record.old_outcome.reason_code == "apply" then
      apply_by_source[timeout_source_state(record)] = record
    end
  end
  for source_state, expected in pairs(TIMEOUT_SOURCES) do
    local record = apply_by_source[source_state]
    t.is_true(record ~= nil, source_state .. ": frozen apply record")
    local incoming_version = record.old_inputs.incoming_version
    local cases = {
      { name = "apply", current = record.old_inputs.current_fact },
      { name = "idempotent", current = { state = "blocked", version = incoming_version } },
      { name = "stale", current = { state = "merged", version = incoming_version } },
    }
    for _, fixture in ipairs(cases) do
      local snapshot = restart_effects.seal_snapshot({
        owner = OWNER,
        entity = { kind = "pr", repo = REPO, number = PR_NUMBER },
        proposal_id = record.typed_intent.lineage.proposal_id,
        current = fixture.current,
        snapshot_fingerprint = "r9-pr-timeout-reconcile|" .. source_state .. "|" .. fixture.name,
        lock_epoch = "r9-pr-timeout-reconcile@" .. incoming_version,
        generation = incoming_version,
      })
      local decision = restart_effects.decide_transition(snapshot, {
        semantic_variant = "watchdog_reconcile_terminal",
        source_boundary = "devloop_timeout_reconcile",
        target = "blocked",
        incoming_version = incoming_version,
        target_version = nil,
        overlay_version = incoming_version,
      })
      local old_status = fixture.name == "apply" and "apply"
        or fixture.name == "idempotent" and "idempotent"
        or "stale"
      local context = source_state .. "/" .. fixture.name
      t.eq(decision.status, old_status, context .. ": owner status equals OLD CAS")
      t.eq(type(decision.cas_outcome), "string", context .. ": owner outcome is recorded")
      t.eq(decision.cas_policy_id, "cas.legacy_timeout_reconcile_v1", context .. ": owner policy")
      if fixture.name == "apply" then
        t.eq(decision.edge_id, OWNER .. "/" .. expected.edge, context .. ": exact source edge")
        t.eq(#decision.granted_effect_ids, 2, context .. ": comment and label grants")
      else
        t.eq(#(decision.granted_effect_ids or {}), 0, context .. ": terminal CAS grants no effects")
      end
    end
  end
end

-- Owner directive (#2725): the timeout watchdog never escalates (decision.action is always
-- redrive), so the reconcile department's timeout path short-circuits BEFORE the CAS
-- boundary with skip-stale(no-longer-over-budget). The over-budget "apply"-family timeout
-- reconciles therefore no longer drop the PR to terminal blocked -- the terminal drop is
-- neutralized. The frozen OLD apply records are retained BYTE-EXACT (no re-record): they
-- encode the CAS-admission scenario that assert_timeout_owner_matrix above validates
-- UNCHANGED (decide_transition / versioned_transition_status still apply on the valid
-- version). Only the DEPARTMENT boundary changed, asserted here -- exactly the byte-exact
-- corpus + separate department-skip pattern used for the github-devloop
-- timeout_reconcile_cas_parity corpus.
local NEUTRALIZED_TIMEOUT_OUTCOME = "skip-stale(no-longer-over-budget)"

local function assert_timeout_production_equals_frozen_old()
  local records = frozen_timeout_records()
  assert_timeout_owner_matrix(records)
  local apply_count = 0
  local pr_apply_count = 0
  local issue_apply_count = 0
  for _, record in ipairs(records) do
    local result, captured = run_timeout_production(record)
    local old = record.old_outcome
    local last_decision = captured.cas_decisions[#captured.cas_decisions]
    if old.status == "apply" then
      -- #2725: the frozen OLD apply is now neutralized pre-cas -- the department skips
      -- with skip-stale(no-longer-over-budget), reaches no CAS/owner decision, constructs
      -- no facade, and emits nothing. (The frozen record's CAS-admission scenario is still
      -- confirmed byte-exact by assert_timeout_owner_matrix.)
      apply_count = apply_count + 1
      t.eq(record.evidence_refs[1].kind, "runtime-cas-probe",
        record.observation_id .. ": frozen baseline retains its protected evidence")
      t.eq(last_decision.outcome, NEUTRALIZED_TIMEOUT_OUTCOME,
        record.observation_id .. ": #2725 neutralizes the terminal drop pre-cas")
      t.eq(#result.raises, 0, record.observation_id .. ": neutralized apply emits no effect")
      t.eq(#captured.owner_decisions, 0, record.observation_id .. ": short-circuits before the CAS boundary")
      t.eq(#captured.facade_families, 0, record.observation_id .. ": no facade constructed")
      t.eq(#captured.facade_emits, 0, record.observation_id .. ": no facade emit")
      if timeout_is_issue_fallback(record) then
        issue_apply_count = issue_apply_count + 1
      else
        pr_apply_count = pr_apply_count + 1
      end
    else
      t.eq(last_decision.outcome, old.cas_outcome, record.observation_id .. ": production disposition")
      t.eq(
        canonical_json(normalized_raises(result.raises)),
        canonical_json(expected_raises(record)),
        record.observation_id .. ": full payloads are byte-exact with frozen OLD"
      )
      t.eq(#captured.owner_decisions, 0, record.observation_id .. ": unchanged pre-CAS guard")
      t.eq(#captured.facade_families, 0, record.observation_id .. ": guard does not construct facade")
      t.eq(#captured.facade_emits, 0, record.observation_id .. ": guard emits no effect")
    end
  end
  t.eq(apply_count, 14, "all frozen timeout apply observations replayed (now neutralized pre-cas)")
  t.eq(pr_apply_count, 8, "PR-surface apply observations replayed (neutralized)")
  t.eq(issue_apply_count, 6, "issue-surface apply observations replayed (neutralized)")
end

return {
  test_review_reconcile_production_grant_facade_equals_frozen_old = function()
    assert_review_production_equals_frozen_old()
  end,

  test_pr_timeout_reconcile_production_grant_facade_equals_frozen_old = function()
    assert_timeout_production_equals_frozen_old()
  end,
}
