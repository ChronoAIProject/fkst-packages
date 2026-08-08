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
  test_review_meta_live_codex_run_defers_without_redrive_or_timeout_attempt = function()
    local event = h.review_meta_event()
    local row = restart_transition_row("review-meta")
    local state = {
      state = "review-meta",
      version = event.version,
      proposal_id = event.proposal_id,
      marker_created_at = "2026-06-03T02:00:00Z",
    }
    local comments = review_meta_comments(event)
    local facts = timeout_facts(event, state, comments)
    with_codex_runs({
      {
        run_id = "review-meta-live",
        role = "review-meta",
        proposal_id = event.proposal_id,
        dedup_key = event.version,
        status = "running",
        lease_expires_at_ms = (now() + 3600) * 1000,
      },
    }, function()
      local receiver = core.restart_row_receiver_liveness(row, state, facts, facts.now_seconds)
      t.eq(receiver.action, "defer")
      t.eq(receiver.signal.family, "codex_run:v1")
      local raised = capture_raises(function()
        local handled = core.maybe_timeout_redrive_from_table("liveness_scan", {
          repo = repo,
          number = event.pr_number,
          source_ref = entity_lib.pr_source_ref(repo, event.pr_number),
        }, state, row, facts)
        t.eq(handled, true)
      end)
      t.eq(captured_raise(raised, "devloop_review_meta"), nil)
      t.eq(captured_raise(raised, "devloop_timeout_reconcile"), nil)
      t.eq(captured_raise(raised, "github-proxy.github_pr_comment_request", function(payload)
        return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
      end), nil)
    end)
  end,

  test_review_meta_no_codex_run_over_budget_redrives = function()
    local event = h.review_meta_event()
    local row = restart_transition_row("review-meta")
    local state = {
      state = "review-meta",
      version = event.version,
      proposal_id = event.proposal_id,
      marker_created_at = "2026-06-03T00:00:00Z",
    }
    local comments = review_meta_comments(event)
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
      -- Owner directive (#2725): review-meta past budget REDRIVES (next timeout-attempt PR
      -- comment), never escalating to a terminal reconcile.
      t.eq(captured_raise(raised, "devloop_timeout_reconcile"), nil)
      t.is_true(captured_raise(raised, "devloop_review_meta") ~= nil)
      local attempt = captured_raise(raised, "github-proxy.github_pr_comment_request", function(payload)
        return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
      end)
      t.is_true(attempt ~= nil)
      t.is_true(captured_raise_index(raised, "devloop_review_meta")
        < captured_raise_index(raised, "github-proxy.github_pr_comment_request", function(payload)
          return tostring(payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
        end))
      t.is_true(tostring(attempt.payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil)
      t.is_true(tostring(attempt.payload.body or ""):find('state="review-meta"', 1, true) ~= nil)
    end)
  end,

  test_review_meta_live_codex_run_over_budget_force_terminates_at_row_cap = function()
    local event = h.review_meta_event()
    local row = restart_transition_row("review-meta")
    local state = {
      state = "review-meta",
      version = event.version .. "/timeout/review-meta/2",
      proposal_id = event.proposal_id,
      marker_created_at = "2026-06-03T00:00:00Z",
    }
    local comments = review_meta_comments(event, state.version)
    table.insert(comments, timeout_attempt_v2_comment(row, state, comments, 1))
    table.insert(comments, timeout_attempt_v2_comment(row, state, comments, 2))
    local facts = timeout_facts(event, state, comments)
    assert_live_run_over_row_budget_caps(event, row, state, facts, "review-meta", event.version)
  end,

  test_review_meta_dispatch_with_live_run_without_completion_markers_skips_redelivery = function()
    local event = h.review_meta_event()
    local run_opts = opts("review-meta-dispatch-live-run-no-marker")
    fixture.with_live_role_codex_run(run_opts, "review-meta", event.proposal_id, event.version, function()
      h.mock_issue_review_meta({ "fkst-dev:review-meta" }, {
        core.state_marker(event.proposal_id, "review-meta", event.version),
      })
      h.mock_meta_codex("block", "duplicate review-meta should not spawn")

      local result = h.run_review_meta(event, run_opts)
      t.eq(result.exit_code, 0)
      t.eq(#result.raises, 0)
      t.eq(count_calls("codex exec"), 0)
    end)
  end,

  test_review_meta_dispatch_with_expired_codex_run_starts_one_replacement = function()
    local event = h.review_meta_event()
    local run_opts = opts("review-meta-dispatch-expired-run-starts")
    seed_role_codex_run(run_opts, "review-meta", event.proposal_id, event.version, {
      lease_expires_at_ms = (now() - 60) * 1000,
      timeout_seconds = 1,
    })
    h.mock_issue_review_meta({ "fkst-dev:review-meta" }, {
      core.state_marker(event.proposal_id, "review-meta", event.version),
    })
    h.mock_meta_codex("block", "replacement review-meta ran")

    local result = h.run_review_meta(event, run_opts)
    t.eq(result.exit_code, 0)
    t.eq(count_calls("codex exec"), 1)
    local comment = h.find_raise(result.raises, "github-proxy.github_pr_comment_request")
    t.is_true(comment ~= nil)
    t.is_true(tostring(comment.payload.body or ""):find('state="blocked"', 1, true) ~= nil)
  end,
}
