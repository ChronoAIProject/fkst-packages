local fixture = require("tests.liveness_codex_run_helpers")
local devloop_base = fixture.devloop_base
local entity_lib = fixture.entity_lib
local requests_review = fixture.requests_review
local convergence_shared = fixture.convergence_shared
local contract_time = fixture.contract_time
local transition_version = fixture.transition_version
local h = fixture.h
local conv_rounds = fixture.conv_rounds
local conv_attempts = fixture.conv_attempts
local m_rae = fixture.m_rae
local dispatch_live_run = fixture.dispatch_live_run
local t = fixture.t
local core = fixture.core
local opts = fixture.opts
local replay_fields = fixture.replay_fields
local fixing = fixture.fixing
local run_fix = fixture.run_fix
local mock_issue_fix_for_event = fixture.mock_issue_fix_for_event
local mock_pr_fix = fixture.mock_pr_fix
local mock_implement_codex = fixture.mock_implement_codex
local mock_git_status = fixture.mock_git_status
local mock_git_commit = fixture.mock_git_commit
local mock_git_push = fixture.mock_git_push
local mock_existing_fix_worktree = fixture.mock_existing_fix_worktree
local mock_write_env = fixture.mock_write_env
local mock_bot_env = fixture.mock_bot_env
local count_calls = fixture.count_calls
local entity_read_mocks = fixture.entity_read_mocks
local m_builders = fixture.m_builders
local devloop_logging = fixture.devloop_logging
local ci_repair_attempts = fixture.ci_repair_attempts
local ci_repair_retry = fixture.ci_repair_retry
local config = fixture.config
local repo = fixture.repo
local proposal_id = fixture.proposal_id
local restart_transition_row = fixture.restart_transition_row
local nonce = fixture.nonce
local json_string = fixture.json_string
local json_value = fixture.json_value
local json_object = fixture.json_object
local seed_codex_run = fixture.seed_codex_run
local live_run_timing = fixture.live_run_timing
local seed_role_codex_run = fixture.seed_role_codex_run
local trusted_comment = fixture.trusted_comment
local recent_comment = fixture.recent_comment
local fixing_state = fixture.fixing_state
local fixing_comments = fixture.fixing_comments
local review_meta_comments = fixture.review_meta_comments
local timeout_attempt_v2_comment = fixture.timeout_attempt_v2_comment
local timeout_facts = fixture.timeout_facts
local ci_repair_hold_fixture = fixture.ci_repair_hold_fixture
local capture_raises = fixture.capture_raises
local captured_raise = fixture.captured_raise
local captured_raise_index = fixture.captured_raise_index
local with_codex_runs = fixture.with_codex_runs
local with_codex_runs_unavailable = fixture.with_codex_runs_unavailable
local dispatch_liveness = fixture.dispatch_liveness
local mock_repo_and_empty_issue_list = fixture.mock_repo_and_empty_issue_list
local mock_pr_list = fixture.mock_pr_list
local mock_issue_claim = fixture.mock_issue_claim
local mock_pr_state = fixture.mock_pr_state
local reject_comment = fixture.reject_comment
local mock_fix_dispatch_context = fixture.mock_fix_dispatch_context
local run_liveness_scan = fixture.run_liveness_scan
local assert_live_run_over_row_budget_caps = fixture.assert_live_run_over_row_budget_caps

return {
  test_fixing_backoff_hold_excludes_old_state_age_until_due_then_retries = function()
    local event = fixing({
      repair_input = "ci-failure",
      ci_failure_key = "head:def456/checks:digest-0000000101",
    })
    local comments = fixing_comments(event)
    local row = restart_transition_row("fixing")
    local state = fixing_state(event, nil, "2026-06-03T01:00:00Z")
    with_codex_runs({}, function()
      local old_facts = timeout_facts(event, state, comments)
      local old_eval = m_rae.actionable_epoch_resolve(core, row, state, old_facts, old_facts.now_seconds)
      table.insert(comments, trusted_comment(conv_attempts.timeout_attempt_v2_marker(
        proposal_id,
        row.from_state,
        row.liveness_class_id,
        old_eval.generation_key,
        2,
        entity_lib.pr_source_ref(repo, event.pr_number)
      )))
    end)
    table.insert(comments, trusted_comment(
      ci_repair_attempts.comment_request(repo, event, "no-fix", "No repaired revision was published.").body,
      "2026-06-03T02:58:00Z"
    ))
    local unavailable_facts = timeout_facts(event, state, comments)
    unavailable_facts.now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:02:59Z")
    with_codex_runs_unavailable(function()
      local eval = m_rae.actionable_epoch_resolve(core, row, state, unavailable_facts, unavailable_facts.now_seconds)
      t.eq(eval.status, "deferred")
      t.eq(eval.hold.status, "held")
      local decision = core.liveness_timeout_decision_with_facts(row, state, unavailable_facts, unavailable_facts.now_seconds)
      t.eq(decision.action, "wait")
      t.eq(core.liveness_timeout_attempt(row, state, unavailable_facts), 0)
    end)
    local rollup = '[{"__typename":"CheckRun","completedAt":"2026-06-03T02:57:00Z","conclusion":"FAILURE","detailsUrl":"https://example.invalid/checks/test","name":"test","startedAt":"2026-06-03T02:56:00Z","status":"COMPLETED","workflowName":"test","headSha":"def456"}]'
    local function setup_scan()
      mock_repo_and_empty_issue_list()
      mock_pr_list()
      mock_issue_claim()
      mock_pr_state(comments, {
        mergeable = "MERGEABLE",
        merge_state = "UNSTABLE",
        status_check_rollup_json = rollup,
      })
      h.mock_required_check_runs_for("def456", "failure", repo)
    end

    setup_scan()
    local before = run_liveness_scan(
      "liveness-scan-fixing-backoff-before-due",
      opts("liveness-scan-fixing-backoff-before-due"),
      contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:02:59Z")
    )
    t.eq(before.exit_code, 0)
    t.eq(h.find_raise(before.raises, "devloop_timeout_reconcile"), nil)
    t.eq(h.find_raise(before.raises, "github-proxy.github_pr_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
    end), nil)

    local due_facts = timeout_facts(event, state, comments)
    due_facts.now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:03:00Z")
    with_codex_runs({}, function()
      local decision = core.liveness_timeout_decision_with_facts(row, state, due_facts, due_facts.now_seconds)
      t.eq(decision.action, "wait")
      t.eq(core.liveness_timeout_attempt(row, state, due_facts), 0)
    end)

    setup_scan()
    local due = run_liveness_scan(
      "liveness-scan-fixing-backoff-at-due",
      opts("liveness-scan-fixing-backoff-at-due"),
      contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:03:00Z")
    )
    t.eq(due.exit_code, 0)
    t.eq(h.find_raise(due.raises, "devloop_timeout_reconcile"), nil)
    t.eq(h.find_raise(due.raises, "github-proxy.github_pr_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
    end), nil)
    local observe = h.find_raise(due.raises, "devloop_observe_pr")
    t.is_true(observe ~= nil)
    t.eq(h.find_raise(due.raises, "devloop_fixing"), nil)
  end,

  test_fixing_durable_completion_dominates_stale_live_run_for_same_generation = function()
    local _, _, state, row, facts, _, delay_seconds = ci_repair_hold_fixture("2026-06-03T01:00:00Z")
    local due_seconds = math.max(
      contract_time.iso_timestamp_epoch_seconds(state.marker_created_at),
      contract_time.iso_timestamp_epoch_seconds(transition_version.updated_at(state.version))
    ) + delay_seconds
    facts.now_seconds = due_seconds
    local durable_hold = ci_repair_retry.resolve_liveness_hold(row, state, facts, due_seconds)
    t.eq(durable_hold.status, "released")
    local expected_dedup_key
    with_codex_runs({}, function()
      expected_dedup_key = core.restart_row_liveness_signal(row, state, facts, due_seconds).expected_dedup_key
    end)
    with_codex_runs({
      {
        run_id = "stale-completed-fixing-run",
        role = "fix",
        proposal_id = state.proposal_id,
        dedup_key = expected_dedup_key,
        status = "running",
        lease_expires_at_ms = (due_seconds + math.floor(row.watchdog.budget_ms / 1000)) * 1000,
      },
    }, function()
      local eval = m_rae.actionable_epoch_resolve(core, row, state, facts, due_seconds)
      t.eq(eval.status, "actionable")
      t.eq(eval.hold.status, "released")
      t.eq(eval.hold.attempt.version, state.version)
      t.eq(eval.epoch_ms, due_seconds * 1000)
    end)
  end,

  test_fixing_live_codex_run_defers_without_redrive_or_timeout_attempt = function()
    local event = fixing()
    local row = restart_transition_row("fixing")
    local state = fixing_state(event, nil, "2026-06-03T01:30:00Z")
    local comments = fixing_comments(event)
    local facts = timeout_facts(event, state, comments)
    with_codex_runs({
      {
        run_id = "fix-live",
        role = "fix",
        proposal_id = event.proposal_id,
        dedup_key = event.work_unit_key,
        status = "running",
        lease_expires_at_ms = (now() + 3600) * 1000,
      },
    }, function()
      local receiver = core.restart_row_receiver_liveness(row, state, facts, facts.now_seconds)
      t.eq(receiver.action, "defer")
      t.eq(receiver.signal.family, "codex_run:v1")
      local due = core.liveness_timeout_due_with_facts(row, state, facts, facts.now_seconds)
      t.eq(due, false)
      local raised = capture_raises(function()
        local handled = core.maybe_timeout_redrive_from_table("liveness_scan", {
          repo = repo,
          number = event.pr_number,
          source_ref = entity_lib.pr_source_ref(repo, event.pr_number),
        }, state, row, facts)
        t.eq(handled, true)
      end)
      t.eq(captured_raise(raised, "devloop_fixing"), nil)
      t.eq(captured_raise(raised, "devloop_timeout_reconcile"), nil)
      t.eq(captured_raise(raised, "github-proxy.github_pr_comment_request", function(payload)
        return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
      end), nil)
    end)
  end,

  test_fixing_no_codex_run_over_budget_redrives_never_reaching_blocked = function()
    local event = fixing()
    local row = restart_transition_row("fixing")
    local state = fixing_state(event)
    local comments = fixing_comments(event)
    table.insert(comments, timeout_attempt_v2_comment(row, state, comments, 1))
    table.insert(comments, timeout_attempt_v2_comment(row, state, comments, 2))
    local facts = timeout_facts(event, state, comments)
    with_codex_runs({}, function()
      local due, age = core.liveness_timeout_due_with_facts(row, state, facts, facts.now_seconds)
      t.eq(due, true)
      t.eq(age, 180)
      local raised = capture_raises(function()
        local handled = core.maybe_timeout_redrive_from_table("liveness_scan", {
          repo = repo,
          number = event.pr_number,
          source_ref = entity_lib.pr_source_ref(repo, event.pr_number),
        }, state, row, facts)
        t.eq(handled, true)
      end)
      -- Owner directive (#2725): fixing past budget with no live codex REDRIVES (emits the
      -- next timeout-attempt PR comment) and NEVER escalates to a terminal reconcile /
      -- blocked -- the timeout is a counter, not an explicit cannot-proceed.
      t.eq(captured_raise(raised, "devloop_timeout_reconcile"), nil)
      t.is_true(captured_raise(raised, "devloop_fixing") ~= nil)
      local attempt = captured_raise(raised, "github-proxy.github_pr_comment_request", function(payload)
        return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
      end)
      t.is_true(attempt ~= nil)
      t.is_true(captured_raise_index(raised, "devloop_fixing")
        < captured_raise_index(raised, "github-proxy.github_pr_comment_request", function(payload)
          return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
        end))
      t.is_true(tostring(attempt.payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil)
      t.is_true(tostring(attempt.payload.body or ""):find('state="fixing"', 1, true) ~= nil)
    end)
  end,

  test_fixing_live_codex_run_over_budget_force_terminates_at_row_cap = function()
    local event = fixing()
    local row = restart_transition_row("fixing")
    local state = fixing_state(event, event.version .. "/timeout/fixing/2")
    local comments = fixing_comments(event, state.version)
    table.insert(comments, timeout_attempt_v2_comment(row, state, comments, 1))
    table.insert(comments, timeout_attempt_v2_comment(row, state, comments, 2))
    local facts = timeout_facts(event, state, comments)
    assert_live_run_over_row_budget_caps(event, row, state, facts, "fix", event.work_unit_key)
  end,

  test_liveness_scan_fixing_live_codex_run_drops_redrive = function()
    local event = fixing()
    local run_opts = opts("liveness-scan-fixing-live-codex")
    local comments = {
      recent_comment(m_builders.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")),
      recent_comment(core.state_marker(event.proposal_id, "fixing", event.version)),
      recent_comment(m_builders.review_result_marker(event.review_proposal_id, event.proposal_id, "reject", event.review_dedup_key, 1, "missing regression guard")),
      recent_comment(m_builders.merge_gate_marker(event.proposal_id,
        event.pr_number,
        event.version,
        event.review_proposal_id,
        event.review_dedup_key,
        event.reviewed_head_sha,
        nil,
        "missing regression guard",
        nil,
        event.ci_failure_key
      )),
    }
    seed_role_codex_run(run_opts, "fix", event.proposal_id, event.work_unit_key)
    mock_repo_and_empty_issue_list()
    mock_pr_list()
    mock_issue_claim()
    mock_pr_state(comments)

    local result = run_liveness_scan("liveness-scan-fixing-live-codex", run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.find_raise(result.raises, "devloop_fixing"), nil)
    t.eq(h.find_raise(result.raises, "devloop_timeout_reconcile"), nil)
    t.eq(h.find_raise(result.raises, "github-proxy.github_pr_comment_request", function(payload)
      return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
    end), nil)
  end,

  test_fixing_dispatch_with_live_run_without_completion_markers_skips_redelivery = function()
    local event = fixing()
    local branch = devloop_base.implement_branch(repo, "42", event.version)
    local rejection = reject_comment(event)
    local run_opts = opts("fixing-dispatch-live-run-no-marker", { FKST_GITHUB_WRITE = "1" })
    seed_role_codex_run(run_opts, "fix", event.proposal_id, event.work_unit_key)
    mock_fix_dispatch_context(event, branch, rejection)
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', { stdout = "/tmp/fkst-packages-test/github-devloop/runtime", stderr = "", exit_code = 0 })
    mock_existing_fix_worktree(branch, event.reviewed_head_sha)
    mock_implement_codex(0, "duplicate fix should not spawn")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("feedface", branch)
    mock_write_env("1")
    mock_fix_dispatch_context(event, branch, rejection, 0)
    mock_git_push(branch)
    mock_pr_fix({ m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev") }, branch, "feedface")

    local result = run_fix(event, run_opts)
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git worktree add --force -B"), 0)
    t.eq(count_calls("git worktree remove --force"), 0)
    t.eq(count_calls("git worktree prune"), 0)
    t.eq(count_calls("merge --no-edit"), 0)
  end,

  test_fixing_dispatch_dedup_uses_shared_codex_run_liveness = function()
    local event = fixing()
    local state = fixing_state(event)
    local facts = timeout_facts(event, state, fixing_comments(event))
    facts.now_seconds = now()
    local liveness = dispatch_liveness()
    with_codex_runs({
      {
        run_id = "fix-live",
        role = "fix",
        proposal_id = event.proposal_id,
        dedup_key = event.work_unit_key,
        status = "running",
        lease_expires_at_ms = (now() + 3600) * 1000,
      },
    }, function()
      t.eq(dispatch_live_run.dispatch_live_run_dedup(liveness, "fix", event.proposal_id, event.work_unit_key, facts), true)
    end)
    with_codex_runs({
      {
        run_id = "fix-expired",
        role = "fix",
        proposal_id = event.proposal_id,
        dedup_key = event.work_unit_key,
        status = "running",
        lease_expires_at_ms = (now() - 60) * 1000,
      },
    }, function()
      t.eq(dispatch_live_run.dispatch_live_run_dedup(liveness, "fix", event.proposal_id, event.work_unit_key, facts), false)
    end)
  end,

  test_fixing_dispatch_with_expired_codex_run_deadline_starts_one_replacement = function()
    local event = fixing()
    local branch = devloop_base.implement_branch(repo, "42", event.version)
    local rejection = reject_comment(event)
    local run_opts = opts("fixing-dispatch-expired-run-starts", {
      FKST_GITHUB_WRITE = "1",
    })
    seed_role_codex_run(run_opts, "fix", event.proposal_id, event.work_unit_key, {
      lease_expires_at_ms = (now() - 60) * 1000,
      timeout_seconds = 1,
    })
    mock_fix_dispatch_context(event, branch, rejection)
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', { stdout = "/tmp/fkst-packages-test/github-devloop/runtime", stderr = "", exit_code = 0 })
    mock_existing_fix_worktree(branch, event.reviewed_head_sha)
    mock_implement_codex(0, "replacement fix applied")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("feedface", branch)
    mock_write_env("1")
    mock_fix_dispatch_context(event, branch, rejection, 0)
    mock_git_push(branch)
    mock_pr_fix({ m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev") }, branch, "feedface")

    local result = run_fix(event, run_opts)
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    t.eq(count_calls("git push origin"), 1)
  end,

  test_fixing_codex_run_match_preserves_fix_suffix = function()
    local event = fixing()
    local row = restart_transition_row("fixing")
    local state = fixing_state(event)
    local facts = timeout_facts(event, state, fixing_comments(event))
    with_codex_runs({
      {
        run_id = "base-only-wrong",
        role = "fix",
        proposal_id = event.proposal_id,
        dedup_key = transition_version.strip_suffixes(event.version),
        status = "running",
      },
    }, function()
      local signal = core.restart_row_liveness_signal(row, state, facts, facts.now_seconds)
      t.eq(signal.live, false)
      t.eq(signal.expected_dedup_key, event.work_unit_key)
    end)
  end,

}
