local fixture = require("tests.integration_liveness_scan_helpers")
local devloop_state = require("devloop.state")
local base_ids = fixture.base_ids
local h = fixture.h
local entity_lib = fixture.entity_lib
local devloop_base = fixture.devloop_base
local devloop_logging = fixture.devloop_logging
local cache_seed_helpers = fixture.cache_seed_helpers
local contract_time = fixture.contract_time
local conv_reconcile = fixture.conv_reconcile
local conv_attempts = fixture.conv_attempts
local m_rae = fixture.m_rae
local t = fixture.t
local core = fixture.core
local opts = fixture.opts
local decompose_lib = fixture.decompose_lib
local issue = fixture.issue
local mock_issue_state = fixture.mock_issue_state
local run_observe = fixture.run_observe
local find_raise = fixture.find_raise
local render_comment = fixture.render_comment
local json_string = fixture.json_string
local ready = fixture.ready
local replay_fields = fixture.replay_fields
local mock_issue_reconcile = fixture.mock_issue_reconcile
local entity_read_mocks = fixture.entity_read_mocks
local codex_status = fixture.codex_status
local m_builders = fixture.m_builders
local ISSUE_REDRIVE_QUEUE = fixture.ISSUE_REDRIVE_QUEUE
local _cache_seed_helpers = fixture._cache_seed_helpers
local restart_transition_row = fixture.restart_transition_row
local run_timeout_reconcile = fixture.run_timeout_reconcile
local repo = fixture.repo
local proposal_id = fixture.proposal_id
local version = fixture.version
local recent_iso = fixture.recent_iso
local run_liveness_scan = fixture.run_liveness_scan
local run_liveness_scan_at = fixture.run_liveness_scan_at
local mock_repo = fixture.mock_repo
local numbered_list_json = fixture.numbered_list_json
local blocked_by_json = fixture.blocked_by_json
local mock_blocked_by = fixture.mock_blocked_by
local mock_issue_list = fixture.mock_issue_list
local mock_issue_state_number = fixture.mock_issue_state_number
local mock_empty_pr_list = fixture.mock_empty_pr_list
local mock_branch_config = fixture.mock_branch_config
local mock_pr_list = fixture.mock_pr_list
local mock_pr_state = fixture.mock_pr_state
local mock_linked_pr_state = fixture.mock_linked_pr_state
local mock_linked_pr_absent = fixture.mock_linked_pr_absent
local assert_no_entity_change = fixture.assert_no_entity_change
local entity_change_issue_numbers = fixture.entity_change_issue_numbers
local has_liveness_action_for_proposal = fixture.has_liveness_action_for_proposal
local timeout_state_comment = fixture.timeout_state_comment
local recent_state_comment = fixture.recent_state_comment
local ready_state_comment = fixture.ready_state_comment
local timeout_attempt_comment = fixture.timeout_attempt_comment
local timeout_attempt_v2_comment = fixture.timeout_attempt_v2_comment
local with_codex_runs = fixture.with_codex_runs
local capture_timeout_raises_and_logs = fixture.capture_timeout_raises_and_logs
local captured_raise = fixture.captured_raise
local assert_no_observe_reinject = fixture.assert_no_observe_reinject
local issue_rest_view_number = fixture.issue_rest_view_number

return {
  test_liveness_scan_skips_over_budget_ready_dependency_hold_timeout = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" }, "OPEN", {
      timeout_state_comment("dependency_wait", version, "2026-06-03T00:00:00Z"),
      "github-devloop dependency hold: waiting\n\nReason: waiting-on-dependency\n\n"
        .. core.dependency_wait_marker(proposal_id, version, { 271 }),
    })
    mock_empty_pr_list()

    local result = run_liveness_scan("liveness-scan-ready-dependency-hold-timeout-skip")
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "devloop_timeout_reconcile"), nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    local raised = find_raise(result.raises, ISSUE_REDRIVE_QUEUE)
    t.is_true(raised ~= nil)
    t.eq(raised.payload.type, "issue")
  end,

  test_liveness_scan_over_budget_ready_writes_timeout_redrive_without_observe = function()
    mock_blocked_by(42, {})
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready" }, "OPEN", { ready_state_comment("IC_ready_timeout", version) })
    mock_empty_pr_list()
    local result = run_liveness_scan("liveness-scan-ready-timeout-redrive")
    t.eq(result.exit_code, 0)
    assert_no_observe_reinject(result)
    local ready_raise = find_raise(result.raises, "devloop_ready")
    t.is_true(ready_raise ~= nil)
    t.eq(ready_raise.payload.proposal_id, proposal_id)
    t.is_true(ready_raise.payload.dedup_key:find("/redrive/ready/1", 1, true) ~= nil)
    t.eq(ready_raise.payload.ready_hand_off.comment_id, "IC_ready_timeout")
    t.eq(ready_raise.payload.ready_hand_off.marker_version, version)
    t.eq(ready_raise.payload.source_ref.ref, "owner/repo#issue/42")
    local attempt = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(attempt ~= nil)
    t.is_true(attempt.payload.body:find("fkst:github-devloop:timeout-attempt:v1", 1, true) ~= nil)
    t.is_true(attempt.payload.body:find("fkst:github-devloop:timeout-attempt:latest:v1", 1, true) ~= nil)
    t.is_true(tostring(attempt.payload.replace_marker):find("fkst:github-devloop:timeout-attempt:latest:v1", 1, true) ~= nil)
    t.is_true(attempt.payload.body:find('state="ready"', 1, true) ~= nil)
    t.is_true(attempt.payload.body:find('round="1"', 1, true) ~= nil)
  end,

  test_liveness_scan_over_budget_thinking_redrives_live_version_and_writes_attempt = function()
    local timeout_version = version .. "/timeout/thinking/1"
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      timeout_state_comment("thinking", version, "2026-06-03T00:00:00Z"),
      timeout_state_comment("thinking", timeout_version, "2026-06-03T00:10:00Z"),
    })

    local result = run_observe(issue({
      dedup_key = "liveness-scan/thinking-timeout",
      source = "liveness-scan",
    }), opts("liveness-scan-thinking-timeout-redrive-next-round"))
    t.eq(result.exit_code, 0)
    local proposal = find_raise(result.raises, "devloop_consensus_request")
    t.is_true(proposal ~= nil)
    t.eq(proposal.payload.proposal_id, proposal_id)
    t.eq(devloop_state.version_timeout_round(proposal.payload.dedup_key, "thinking"), 0)
    t.is_true(proposal.payload.effect_version == version and proposal.payload.dedup_key ~= version)
    local attempt = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(attempt ~= nil)
    t.is_true(attempt.payload.body:find("fkst:github-devloop:timeout-attempt:v2", 1, true) ~= nil and attempt.payload.body:find('state="thinking"', 1, true) ~= nil)
    t.is_true(attempt.payload.body:find('round="2"', 1, true) ~= nil)
  end,

  test_liveness_scan_bare_observe_reinject_does_not_increment_timeout_attempt = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready" }, "OPEN", {
      timeout_state_comment("ready", version, recent_iso(60)),
    })
    mock_empty_pr_list()

    local result = run_liveness_scan("liveness-scan-ready-bare-observe-no-timeout-increment")
    t.eq(result.exit_code, 0)
    local changed = find_raise(result.raises, ISSUE_REDRIVE_QUEUE)
    t.is_true(changed ~= nil)
    t.eq(find_raise(result.raises, "devloop_ready"), nil)
    t.eq(devloop_state.version_timeout_round(changed.payload.dedup_key, "ready"), 0)
  end,

  test_liveness_scan_over_budget_blocked_redrives_decompose = function()
    local review_proposal = devloop_base.pr_review_proposal_id(repo, 7, version, "def456")
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, "OPEN", {
      timeout_state_comment("blocked", version, "2026-06-01T00:00:00Z"),
      m_builders.pr_link_marker(proposal_id, 7, "devloop-owner-repo-42-01HY", version, "dev"),
      decompose_lib.decomposed_marker(proposal_id, version, 7, 1),
      m_builders.review_result_marker(review_proposal, proposal_id, "reject", "consensus:" .. review_proposal .. "/review", 1, "missing decomposition"),
    })
    t.mock_command(core.gh_issue_list_decompose_children_cmd(repo, proposal_id), {
      stdout = "[]\n",
      stderr = "",
      exit_code = 0,
    })
    mock_empty_pr_list()

    local result = run_liveness_scan("liveness-scan-blocked-timeout-redrive")
    t.eq(result.exit_code, 0)
    assert_no_observe_reinject(result)
    local decompose = find_raise(result.raises, "github-devloop-decompose.devloop_decompose")
    t.is_true(decompose ~= nil)
    t.eq(decompose.payload.proposal_id, proposal_id)
    t.eq(decompose.payload.version, version)
    local attempt = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(attempt ~= nil)
    t.is_true(attempt.payload.body:find(conv_attempts.timeout_attempt_marker(proposal_id, version, "blocked", 1, entity_lib.issue_source_ref(repo, 42)), 1, true) ~= nil)
  end,

  test_liveness_scan_over_budget_ready_redrives_never_reconciles = function()
    local timeout_version = version .. "/timeout/ready/3"
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready" }, "OPEN", {
      {
        body = h.projected_state_comment(proposal_id, "ready", timeout_version),
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T01:02:03Z",
      },
    })

    local result = run_observe(issue({
      dedup_key = "liveness-scan/ready-timeout",
      source = "liveness-scan",
    }), opts("liveness-scan-ready-timeout"))
    t.eq(result.exit_code, 0)
    -- Owner directive (#2725): at/past the former escalation threshold (round 3) a ready
    -- timeout must NEVER reach a terminal reconcile. The observe entry-point defers the
    -- ready-timeout redrive to the liveness sweep (which climbs the timeout-attempt marker,
    -- see test_liveness_scan_ready_timeout_chain_redrives_not_reconciles); observe itself
    -- emits no terminal devloop_timeout_reconcile and never drops ready to blocked.
    t.eq(find_raise(result.raises, "devloop_timeout_reconcile"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request", function(payload)
      for _, l in ipairs(payload.add_labels or {}) do
        if l == "fkst-dev:blocked" then return true end
      end
      return false
    end), nil)
  end,

  test_liveness_scan_timeout_attempt_climbs_and_redrives_across_frozen_sweeps = function()
    local comments = { ready_state_comment("IC_ready_timeout_sweep", version, "2026-06-03T00:00:00Z") }
    for sweep = 1, 3 do
      mock_blocked_by(42, {})
      mock_repo()
      local updated_at = "2026-06-03T02:00:0" .. tostring(sweep) .. "Z"
      mock_issue_list({ { number = 42, state = "open", updated_at = updated_at } })
      mock_issue_state_number(42, { "fkst-dev:enabled", "fkst-dev:ready" }, "OPEN", comments, updated_at)
      mock_empty_pr_list()
      local result = run_liveness_scan("liveness-scan-ready-timeout-sweep-" .. tostring(sweep))
      t.eq(result.exit_code, 0)
      assert_no_observe_reinject(result)
      if sweep < 3 then
        local ready_raise = find_raise(result.raises, "devloop_ready")
        t.is_true(ready_raise ~= nil)
        t.is_true(ready_raise.payload.dedup_key:find("/redrive/ready/" .. tostring(sweep), 1, true) ~= nil)
        t.eq(ready_raise.payload.ready_hand_off.comment_id, "IC_ready_timeout_sweep")
        t.eq(devloop_state.version_timeout_round(ready_raise.payload.dedup_key, "ready"), 0)
        local attempt = find_raise(result.raises, "github-proxy.github_issue_comment_request")
        t.is_true(attempt ~= nil)
        t.is_true(attempt.payload.body:find('round="' .. tostring(sweep) .. '"', 1, true) ~= nil)
        table.insert(comments, timeout_attempt_comment("ready", version, sweep, "2026-06-03T00:0" .. tostring(sweep) .. ":00Z"))
        t.eq(find_raise(result.raises, "devloop_timeout_reconcile"), nil)
      else
        -- Owner directive (#2725): the timeout-attempt COUNTER never escalates to a
        -- terminal reconcile; sweep 3 REDRIVES exactly like sweeps 1-2 (ready hand-off +
        -- the next timeout-attempt marker), never dropping to blocked.
        local ready_raise = find_raise(result.raises, "devloop_ready")
        t.is_true(ready_raise ~= nil)
        t.is_true(ready_raise.payload.dedup_key:find("/redrive/ready/" .. tostring(sweep), 1, true) ~= nil)
        t.eq(devloop_state.version_timeout_round(ready_raise.payload.dedup_key, "ready"), 0)
        local attempt = find_raise(result.raises, "github-proxy.github_issue_comment_request")
        t.is_true(attempt ~= nil)
        t.is_true(attempt.payload.body:find('round="' .. tostring(sweep) .. '"', 1, true) ~= nil)
        t.eq(find_raise(result.raises, "devloop_timeout_reconcile"), nil)
      end
    end
  end,

  test_liveness_scan_ready_timeout_without_handoff_emits_failure_without_receipt = function()
    local live_version = version .. "/timeout/ready/2"
    mock_blocked_by(42, {})
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T02:00:03Z" } })
    mock_issue_state_number(42, { "fkst-dev:enabled", "fkst-dev:ready" }, "OPEN", {
      timeout_state_comment("ready", version, "2026-06-03T00:00:00Z"),
      timeout_state_comment("ready", version .. "/timeout/ready/1", "2026-06-03T00:01:00Z"),
      timeout_state_comment("ready", live_version, "2026-06-03T00:02:00Z"),
    }, "2026-06-03T02:00:03Z")
    mock_empty_pr_list()

    -- A timeout is not a receipt. Without a ready hand-off the entity emits one failure
    -- observation while the aggregate liveness tick ACKs normally.
    local scanned = run_liveness_scan("liveness-scan-ready-timeout-reconcile-chain")
    t.eq(scanned.exit_code, 0)
    t.eq(find_raise(scanned.raises, "devloop_ready"), nil)
    t.eq(find_raise(scanned.raises, "github-proxy.github_issue_comment_request"), nil)
    local failure = find_raise(scanned.raises, ISSUE_REDRIVE_QUEUE)
    t.is_true(failure ~= nil)
    t.eq(failure.payload.proposal_id, proposal_id)
    t.eq(failure.payload.failure.error_class, "timeout-redrive-stuck")
    t.is_true(tostring(failure.payload.failure.fingerprint):match("^fp%-%d+$") ~= nil)
  end,

  test_liveness_scan_timeout_reconcile_no_longer_blocks_ready = function()
    local stale_version = version .. "/timeout/ready/1"
    local live_version = version .. "/timeout/ready/2"
    local payload = conv_reconcile.build_devloop_timeout_reconcile_payload(restart_transition_row("ready"),
      {
        state = "ready",
        version = stale_version,
        proposal_id = proposal_id,
      },
      proposal_id,
      entity_lib.issue_source_ref(repo, 42),
      3
    )
    mock_issue_reconcile({ "fkst-dev:ready" }, {
      timeout_state_comment("ready", live_version, "2026-06-03T00:02:00Z"),
    })
    mock_blocked_by(42, {})

    -- Owner directive (#2725): the timeout-reconcile department path to terminal blocked
    -- is neutralized. The re-derived timeout DECISION is redrive (never escalate), so a
    -- timeout-reconcile event is a no-op skip (no-longer-over-budget); ready is never
    -- dropped to blocked.
    local reconciled = run_timeout_reconcile(payload, opts("liveness-scan-ready-timeout-reconcile-noop"))
    t.eq(reconciled.exit_code, 0)
    t.eq(find_raise(reconciled.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(find_raise(reconciled.raises, "github-proxy.github_issue_label_request"), nil)
  end,

  test_liveness_scan_timeout_reconcile_skips_when_ready_state_advanced = function()
    local stale_version = version .. "/timeout/ready/2"
    local advanced_version = version .. "/timeout/ready/2"
    local payload = conv_reconcile.build_devloop_timeout_reconcile_payload(restart_transition_row("ready"),
      {
        state = "ready",
        version = stale_version,
        proposal_id = proposal_id,
      },
      proposal_id,
      entity_lib.issue_source_ref(repo, 42),
      3
    )
    mock_issue_reconcile({ "fkst-dev:implementing" }, {
      timeout_state_comment("implementing", advanced_version, "2026-06-03T00:02:00Z"),
    })

    local reconciled = run_timeout_reconcile(payload, opts("liveness-scan-ready-timeout-reconcile-advanced-skips"))
    t.eq(reconciled.exit_code, 0)
    t.eq(find_raise(reconciled.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(find_raise(reconciled.raises, "github-proxy.github_issue_label_request"), nil)
  end,

  test_liveness_scan_implementing_emits_timeout_ready_with_frozen_version = function()
    local event = ready()
    local run_opts = opts("liveness-scan-implementing-redrive-scan")
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local stuck = {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 60), exec_ref),
    }
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    h.mock_issue_implement({ "fkst-dev:enabled", "fkst-dev:implementing" }, stuck)
    mock_empty_pr_list()

    local scanned = run_liveness_scan("liveness-scan-implementing-redrive-scan", run_opts)
    t.eq(scanned.exit_code, 0)
    local reraised = find_raise(scanned.raises, "devloop_ready")
    t.eq(reraised ~= nil, true)
    t.eq(reraised.payload.proposal_id, event.proposal_id)
    t.is_true(reraised.payload.dedup_key ~= event.dedup_key)
    t.eq(reraised.payload.implementation_version, event.dedup_key)
    t.eq(core.implementation_attempt_version(reraised.payload.implementation_version, reraised.payload.impl_retry_attempt), event.dedup_key)
    local attempt = find_raise(scanned.raises, "github-proxy.github_issue_comment_request")
    t.is_true(attempt ~= nil)
    t.is_true(attempt.payload.body:find("fkst:github-devloop:timeout-attempt:v2", 1, true) ~= nil)
    t.is_true(attempt.payload.body:find('state="implementing"', 1, true) ~= nil)
  end,

  test_liveness_scan_drops_stale_implement_attempt_when_codex_run_is_running = function()
    local event = ready()
    local run_opts = opts("liveness-scan-live-codex-run-drops-redrive")
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local stale = {
      recent_state_comment("implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 7201), exec_ref),
    }
    local release_codex_run = codex_status.seed_implement_codex_run(
      run_opts, event.proposal_id, event.dedup_key
    )
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    h.mock_issue_implement({ "fkst-dev:enabled", "fkst-dev:implementing" }, stale)
    mock_empty_pr_list()

    local scanned = run_liveness_scan("liveness-scan-live-codex-run-drops-redrive", run_opts)
    release_codex_run()
    t.eq(scanned.exit_code, 0)
    t.eq(find_raise(scanned.raises, "devloop_ready"), nil)
    t.eq(find_raise(scanned.raises, "devloop_timeout_reconcile"), nil)
    t.eq(find_raise(scanned.raises, "github-proxy.github_issue_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt:v2", 1, true) ~= nil
    end), nil)
  end,

  test_liveness_scan_absent_codex_run_redrives_after_budget = function()
    local event = ready()
    local row = restart_transition_row("implementing")
    local timeout_version = event.dedup_key .. "/timeout/implementing/2"
    local state = {
      state = "implementing",
      version = timeout_version,
      proposal_id = event.proposal_id,
      marker_created_at = "2026-06-03T00:00:00Z",
    }
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local attempt_comment = {
      body = core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 7201), exec_ref),
      author_login = "fkst-test-bot",
      created_at = "2026-06-03T00:00:00Z",
    }
    local eval
    with_codex_runs(function()
      fkst.codex_runs = function()
        return { running = {}, recent = {} }
      end
      eval = m_rae.actionable_epoch_resolve(core, row, state, {
        proposal_id = event.proposal_id,
        current = { comments = { attempt_comment } },
      }, contract_time.iso_timestamp_epoch_seconds("2026-06-03T11:00:00Z"))
    end)
    local comments = {
      timeout_state_comment("implementing", timeout_version, "2026-06-03T00:00:00Z"),
      attempt_comment,
      timeout_attempt_v2_comment(row, eval.generation_key, 1, "2026-06-03T00:01:00Z"),
      timeout_attempt_v2_comment(row, eval.generation_key, 2, "2026-06-03T00:02:00Z"),
    }

    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T11:00:00Z" } })
    h.mock_issue_implement({ "fkst-dev:enabled", "fkst-dev:implementing" }, comments)
    mock_empty_pr_list()

    local scanned = run_liveness_scan("liveness-scan-absent-codex-run-escalates")
    t.eq(scanned.exit_code, 0)
    -- Owner directive (#2725): implementing past budget with no live codex REDRIVES the
    -- ready hand-off and emits the next timeout-attempt marker; it NEVER escalates to a
    -- terminal reconcile / blocked (the timeout is a counter, not an explicit block).
    t.eq(find_raise(scanned.raises, "devloop_timeout_reconcile"), nil)
    local reraised = find_raise(scanned.raises, "devloop_ready")
    t.is_true(reraised ~= nil)
    t.eq(reraised.payload.proposal_id, event.proposal_id)
    local attempt = find_raise(scanned.raises, "github-proxy.github_issue_comment_request")
    t.is_true(attempt ~= nil)
    t.is_true(attempt.payload.body:find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil)
    t.is_true(attempt.payload.body:find('state="implementing"', 1, true) ~= nil)
  end,

  test_codex_runs_error_over_budget_redrives_timeout_decision = function()
    local event = ready()
    local row = restart_transition_row("implementing")
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local timeout_version = event.dedup_key .. "/timeout/implementing/2"
    local state = {
      state = "implementing",
      version = timeout_version,
      proposal_id = event.proposal_id,
      marker_created_at = "2026-06-03T00:00:00Z",
    }
    local comments = {
      {
        body = core.state_marker(event.proposal_id, "implementing", timeout_version),
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T00:00:00Z",
      },
      {
        body = core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 60), exec_ref),
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T00:00:00Z",
      },
    }
    local facts = {
      proposal_id = event.proposal_id,
      source_ref = event.source_ref,
      current = { comments = comments },
      fresh_current_state = state,
      now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T11:00:00Z"),
    }

    with_codex_runs(function()
      fkst.codex_runs = function()
        error("synthetic codex_runs failure")
      end
      local due, age = core.liveness_timeout_due_with_facts(row, state, facts, facts.now_seconds)
      t.eq(due, true)
      t.eq(age, 660)
      local eval = facts.actionable_epoch_eval
      t.eq(eval.status, "actionable")
      t.eq(eval.signal.reason, "codex-runs-unavailable")
      t.eq(eval.signal.codex_runs_fallback, true)
      table.insert(facts.current.comments, timeout_attempt_v2_comment(row, eval.generation_key, 1, "2026-06-03T00:01:00Z"))
      table.insert(facts.current.comments, timeout_attempt_v2_comment(row, eval.generation_key, 2, "2026-06-03T00:02:00Z"))
      local raised, logs = capture_timeout_raises_and_logs(function()
        local applied = core.maybe_timeout_redrive_from_table("liveness_scan", {
          repo = repo,
          number = 42,
          source_ref = entity_lib.issue_source_ref(repo, 42),
        }, state, row, facts)
        t.eq(applied, true)
      end)
      -- Owner directive (#2725): a codex-runs-unavailable fallback over budget is a
      -- liveness-indeterminate condition that must NEVER escalate to a terminal
      -- reconcile; it REDRIVES (re-dispatches the implement via devloop_ready + emits the
      -- next timeout-attempt marker) instead of dropping to blocked.
      t.eq(captured_raise(raised, "devloop_timeout_reconcile"), nil)
      t.is_true(captured_raise(raised, "devloop_ready") ~= nil)
      local attempt = captured_raise(raised, "github-proxy.github_issue_comment_request")
      t.is_true(attempt ~= nil)
      t.is_true(attempt.payload.body:find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil)
      local logged_fallback = false
      for _, log in ipairs(logs) do
        if log.tag == "CODEX_RUNS" and table.concat(log.fields or {}, " "):find("outcome=defer", 1, true) ~= nil then
          logged_fallback = true
        end
      end
      t.eq(logged_fallback, true)
    end)
  end,
}
