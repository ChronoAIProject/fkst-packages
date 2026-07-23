local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local h = require("tests.devloop_helpers")
local contract_time = require("contract.time")
local conv_attempts = require("devloop.convergence.attempts")
local m_rae = require("devloop.restart_actionable_epoch")
local replay_fields = require("devloop.replay_fields")
local devloop_logging = require("devloop.logging")
local t = h.t
local core = h.core
local opts = h.opts
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local codex_status = require("tests.codex_status_helpers")
local decompose_lib = require("devloop.decompose")
local m_builders = require("devloop.markers.builders")

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function encode_json_string(value)
  return h.encode_json_string(value)
end

local function render_comment(comment)
  return h.render_comment(comment)
end

local function mock_repo()
  t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_list(updated_at)
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = '[{"number":42,"state":"open","updated_at":"' .. encode_json_string(updated_at or "2026-06-03T01:02:03Z") .. '"}]\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_empty_pr_list()
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_state(labels, comments, updated_at)
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = 42,
    title = "Issue 42",
    body = "",
    state = "OPEN",
    updated_at = updated_at or "2026-06-03T01:02:03Z",
    labels = labels,
    comments = comments,
    assignees = { "fkst-test-bot" },
    times = 1,
  })
end

local function mock_decompose_children()
  t.mock_command(core.gh_issue_list_decompose_children_cmd(repo, proposal_id), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function run_liveness_scan(name, run_opts)
  return h.run_department("departments/liveness_scan/main.lua", {
    queue = "devloop_liveness_tick",
    payload = { schema = "github-devloop.tick.v1" },
    ts = "2026-06-03T01:32:03Z",
  }, run_opts or opts(name or "liveness-timeout-attempt"))
end

local function find_raise(result, queue)
  return h.find_raise(result.raises, queue)
end

local function count_raises(result, queue)
  local count = 0
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue then
      count = count + 1
    end
  end
  return count
end

local function restart_transition_row(state_name)
  return replay_fields.restart_transition_row(core.restart_transition_table(), state_name)
end

local function capture_raises(fn)
  local raised = {}
  local original = devloop_logging.log_raise
  devloop_logging.log_raise = function(_, _, queue, payload)
    table.insert(raised, { queue = queue, payload = payload })
  end
  local ok, err = pcall(fn)
  devloop_logging.log_raise = original
  if not ok then
    error(err)
  end
  return raised
end

local function captured_raise(raised, queue)
  for _, item in ipairs(raised or {}) do
    if item.queue == queue then
      return item
    end
  end
  return nil
end

local function with_codex_runs(running, fn)
  local original = fkst.codex_runs
  fkst.codex_runs = function()
    return { running = running or {}, recent = {} }
  end
  local ok, err = pcall(fn)
  fkst.codex_runs = original
  if not ok then
    error(err)
  end
end

local function state_comment(state_name, state_version, created_at)
  return {
    body = core.state_marker(proposal_id, state_name, state_version),
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function recent_state_comment(state_name, state_version, seconds_ago)
  return state_comment(state_name, state_version, os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (seconds_ago or 60)))
end

local function issue_comment(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at or "2026-06-03T00:00:00Z",
  }
end

local function assert_no_timeout_progress(result)
  t.eq(find_raise(result, "devloop_timeout_reconcile"), nil)
  t.eq(find_raise(result, "devloop_ready"), nil)
  local comment = find_raise(result, "github-proxy.github_issue_comment_request")
  t.eq(comment, nil)
end

return {
  test_timeout_attempt_not_counted_while_implement_codex_run_live = function()
    local event = h.ready()
    local live_opts = opts("liveness-live-implement-codex-run-no-timeout-count")
    local live_exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    codex_status.seed_implement_codex_run(live_opts, event.proposal_id, event.dedup_key)
    local comments = {
      recent_state_comment("implementing", event.dedup_key),
      issue_comment(core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 7201), live_exec_ref)),
    }
    mock_repo()
    mock_issue_list()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, comments)
    mock_empty_pr_list()

    local scanned = run_liveness_scan("liveness-live-implement-codex-run-no-timeout-count", live_opts)
    t.eq(scanned.exit_code, 0)
    assert_no_timeout_progress(scanned)

    local dead_opts = opts("liveness-absent-implement-codex-run-counts")
    local dead_exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local expired = {
      state_comment("implementing", event.dedup_key, "2026-06-03T00:00:00Z"),
      issue_comment(core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 60), dead_exec_ref)),
    }
    mock_repo()
    mock_issue_list("2026-06-03T01:02:04Z")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:implementing" }, expired, "2026-06-03T01:02:04Z")
    mock_empty_pr_list()

    local redriven = run_liveness_scan("liveness-absent-implement-codex-run-counts", dead_opts)
    t.eq(redriven.exit_code, 0)
    t.eq(find_raise(redriven, "devloop_timeout_reconcile"), nil)
    t.eq(find_raise(redriven, "devloop_ready") ~= nil, true)
    local attempt = find_raise(redriven, "github-proxy.github_issue_comment_request")
    t.is_true(attempt ~= nil)
    t.is_true(attempt.payload.body:find("fkst:github-devloop:timeout-attempt:v2", 1, true) ~= nil)
    t.is_true(attempt.payload.body:find("fkst:github-devloop:timeout-attempt:latest:v1", 1, true) ~= nil)
    t.is_true(tostring(attempt.payload.replace_marker):find("fkst:github-devloop:timeout-attempt:latest:v1", 1, true) ~= nil)
    t.is_true(attempt.payload.body:find('state="implementing"', 1, true) ~= nil)
  end,

  test_delegated_implementing_past_budget_blocked_pr_child_is_actionable = function()
    local event = h.ready()
    local row = restart_transition_row("implementing")
    local state = {
      state = "implementing",
      version = event.dedup_key,
      proposal_id = event.proposal_id,
      marker_created_at = "2026-06-03T00:00:00Z",
    }
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z")
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    local pr_proposal = entity_lib.pr_proposal_id(repo, 7)
    local source_ref = entity_lib.issue_source_ref(repo, 42)
    local comments = {
      state_comment("implementing", event.dedup_key, state.marker_created_at),
      issue_comment(core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, tostring(now() - 60), exec_ref)),
      issue_comment(m_builders.pr_delegation_marker(event.proposal_id, pr_proposal, 7, event.dedup_key, "g1")),
    }
    local facts = {
      proposal_id = event.proposal_id,
      source_ref = source_ref,
      current = { comments = comments, labels = { "fkst-dev:enabled", "fkst-dev:implementing" } },
      current_pr = {
        comments = {
          issue_comment(core.state_marker(pr_proposal, "blocked", "child-blocked-version"), "2026-06-03T01:00:00Z"),
        },
      },
      fresh_current_state = state,
      now_seconds = now_seconds,
    }

    with_codex_runs({}, function()
      -- With the delegated child_workflow_wait machinery deleted, an implementing row
      -- past budget with NO live codex (the faithful #2687 shape: the implement codex
      -- has died/handed off to a now-terminal child PR) is governed only by codex_run:v1.
      -- The codex run is not running, so the actionable-epoch resolves actionable and the
      -- receiver reports action="stuck" (force-terminate), NOT defer. This is the plain
      -- codex-run-not-running path, distinct from the live-codex row-budget-absolute-cap
      -- path exercised by test_stale_pr_delegation_does_not_suppress_implementing_row_budget_cap.
      local receiver = core.restart_row_receiver_liveness(row, state, facts, now_seconds)
      t.eq(receiver.action, "stuck")
      t.eq(receiver.reason, "actionable-epoch-actionable")
      local eval = m_rae.actionable_epoch_resolve(core, row, state, facts, now_seconds)
      t.eq(eval.status, "actionable")
      t.eq(eval.epoch_source, "codex_run:v1")
      t.eq(eval.row_budget_absolute_cap, nil)
      for round = 1, 2 do
        table.insert(comments, issue_comment(conv_attempts.timeout_attempt_v2_marker(
          event.proposal_id,
          row.from_state,
          row.liveness_class_id,
          eval.generation_key,
          round,
          source_ref
        )))
      end
      local raised = capture_raises(function()
        local handled = core.maybe_timeout_redrive_from_table("liveness_scan", {
          repo = repo,
          number = 42,
          source_ref = source_ref,
        }, state, row, facts)
        t.eq(handled, true)
      end)
      t.eq(captured_raise(raised, "devloop_ready"), nil)
      local reconcile = captured_raise(raised, "devloop_timeout_reconcile")
      t.is_true(reconcile ~= nil)
      t.eq(reconcile.payload.state, "implementing")
      t.eq(reconcile.payload.issue_version, event.dedup_key)
      t.eq(reconcile.payload.round, 3)
    end)
  end,

  test_stale_pr_delegation_does_not_suppress_implementing_row_budget_cap = function()
    local event = h.ready()
    local row = restart_transition_row("implementing")
    local state = {
      state = "implementing",
      version = event.dedup_key .. "/timeout/implementing/2",
      proposal_id = event.proposal_id,
      marker_created_at = "2026-06-03T00:00:00Z",
    }
    local now_seconds = contract_time.iso_timestamp_epoch_seconds("2026-06-03T03:00:00Z")
    local pr_proposal = entity_lib.pr_proposal_id(repo, 7)
    local invalid_cases = {
      {
        name = "wrong-proposal",
        comment = m_builders.pr_delegation_marker(event.proposal_id .. "/stale", pr_proposal, 7, state.version, "g1"),
      },
      {
        name = "wrong-version",
        comment = m_builders.pr_delegation_marker(event.proposal_id, pr_proposal, 7, event.dedup_key .. "/stale", "g1"),
      },
      {
        name = "missing-pr-number",
        direct = { proposal_id = event.proposal_id, version = state.version, pr_proposal_id = pr_proposal },
      },
      {
        name = "missing-pr-proposal",
        direct = { proposal_id = event.proposal_id, version = state.version, pr_number = 7 },
      },
    }

    for _, case in ipairs(invalid_cases) do
      local comments = {
        state_comment("implementing", state.version, state.marker_created_at),
      }
      if case.comment ~= nil then
        table.insert(comments, issue_comment(case.comment))
      end
      local facts = {
        proposal_id = event.proposal_id,
        source_ref = entity_lib.issue_source_ref(repo, 42),
        current = { comments = comments, labels = { "fkst-dev:enabled", "fkst-dev:implementing" } },
        fresh_current_state = state,
        now_seconds = now_seconds,
        pr_delegation = case.direct,
      }
      with_codex_runs({
        {
          run_id = "stale-delegation-live-" .. case.name,
          role = "implement",
          proposal_id = event.proposal_id,
          dedup_key = event.dedup_key,
          status = "running",
          started_at = "2026-06-03T02:30:00Z",
          timeout_seconds = 3600,
        },
      }, function()
        local receiver = core.restart_row_receiver_liveness(row, state, facts, now_seconds)
        t.eq(receiver.action, "stuck", case.name)
        t.eq(receiver.reason, "row-budget-absolute-cap", case.name)
        t.eq(receiver.age_minutes, 180, case.name)
        local eval = m_rae.actionable_epoch_resolve(core, row, state, facts, now_seconds)
        for round = 1, 2 do
          table.insert(comments, issue_comment(conv_attempts.timeout_attempt_v2_marker(
            event.proposal_id,
            row.from_state,
            row.liveness_class_id,
            eval.generation_key,
            round,
            entity_lib.issue_source_ref(repo, 42)
          )))
        end
        local raised = capture_raises(function()
          local handled = core.maybe_timeout_redrive_from_table("liveness_scan", {
            repo = repo,
            number = 42,
            source_ref = entity_lib.issue_source_ref(repo, 42),
          }, state, row, facts)
          t.eq(handled, true, case.name)
        end)
        t.eq(captured_raise(raised, "devloop_ready"), nil, case.name)
        local reconcile = captured_raise(raised, "devloop_timeout_reconcile")
        t.is_true(reconcile ~= nil, case.name)
        t.eq(reconcile.payload.state, "implementing", case.name)
        t.eq(reconcile.payload.issue_version, state.version, case.name)
        t.eq(reconcile.payload.round, 3, case.name)
      end)
    end
  end,

  test_blocked_decompose_exhaustion_reaches_non_recycling_terminal_stop = function()
    local review_proposal = devloop_base.pr_review_proposal_id(repo, 7, version, "def456")
    local comments = {
      state_comment("blocked", version, "2026-06-01T00:00:00Z"),
      m_builders.pr_link_marker(proposal_id, 7, "devloop-owner-repo-42-01HY", version, "dev"),
      decompose_lib.decomposed_marker(proposal_id, version, 7, 1),
      m_builders.review_result_marker(review_proposal, proposal_id, "reject", "consensus:" .. review_proposal .. "/review", 1, "missing decomposition"),
      issue_comment(conv_attempts.timeout_attempt_marker(proposal_id, version .. "/timeout-reconcile/blocked/1", "blocked", 1, entity_lib.issue_source_ref(repo, 42))),
      issue_comment(conv_attempts.timeout_attempt_marker(proposal_id, version .. "/timeout-reconcile/blocked/2", "blocked", 2, entity_lib.issue_source_ref(repo, 42))),
    }
    mock_repo()
    mock_issue_list()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, comments)
    mock_decompose_children()
    mock_empty_pr_list()

    local exhausted = run_liveness_scan("liveness-blocked-decompose-exhausted")
    t.eq(exhausted.exit_code, 0)
    t.eq(find_raise(exhausted, "github-devloop-decompose.devloop_decompose"), nil)
    t.eq(find_raise(exhausted, "devloop_timeout_reconcile"), nil)
    t.eq(count_raises(exhausted, "github-proxy.github_issue_comment_request"), 1)
    local stop = find_raise(exhausted, "github-proxy.github_issue_comment_request")
    t.is_true(stop.payload.body:find(conv_attempts.decompose_exhausted_marker(proposal_id, version, 3, entity_lib.issue_source_ref(repo, 42)), 1, true) ~= nil)

    table.insert(comments, issue_comment(conv_attempts.decompose_exhausted_marker(proposal_id, version .. "/timeout-reconcile/blocked/3", 3, entity_lib.issue_source_ref(repo, 42))))
    mock_repo()
    mock_issue_list("2026-06-04T01:02:03Z")
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, comments, "2026-06-04T01:02:03Z")
    mock_empty_pr_list()

    local second = run_liveness_scan("liveness-blocked-decompose-exhausted-second-window")
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 0)
  end,

  test_impl_failed_retry_limit_replay_decline_climbs_to_timeout_reconcile_without_seeded_timeout_markers = function()
    local event = h.ready()
    local comments = {
      state_comment("impl-failed", event.dedup_key, "2026-06-01T00:00:00Z"),
      issue_comment(core.impl_failure_marker(event.proposal_id, event.dedup_key, "codex-failed", core._max_impl_auto_retry_attempts)),
    }

    for sweep = 1, 3 do
      mock_repo()
      mock_issue_list("2026-06-03T01:02:0" .. tostring(sweep) .. "Z")
      mock_issue_state({ "fkst-dev:enabled", "fkst-dev:impl-failed" }, comments, "2026-06-03T01:02:0" .. tostring(sweep) .. "Z")
      mock_empty_pr_list()

      local result = run_liveness_scan("liveness-impl-failed-retry-limit-stuck-sweep-" .. tostring(sweep))
      t.eq(result.exit_code, 0)
      t.eq(find_raise(result, "devloop_ready"), nil)
      if sweep < 3 then
        t.eq(find_raise(result, "devloop_timeout_reconcile"), nil)
        local attempt = find_raise(result, "github-proxy.github_issue_comment_request")
        t.is_true(attempt ~= nil)
        t.is_true(attempt.payload.body:find(conv_attempts.timeout_attempt_marker(event.proposal_id, event.dedup_key, "impl-failed", sweep, entity_lib.issue_source_ref(repo, 42)), 1, true) ~= nil)
        table.insert(comments, issue_comment(conv_attempts.timeout_attempt_marker(event.proposal_id, event.dedup_key, "impl-failed", sweep, entity_lib.issue_source_ref(repo, 42))))
      else
        t.eq(find_raise(result, "github-proxy.github_issue_comment_request"), nil)
        local reconcile = find_raise(result, "devloop_timeout_reconcile")
        t.is_true(reconcile ~= nil)
        t.eq(reconcile.payload.state, "impl-failed")
        t.eq(reconcile.payload.issue_version, event.dedup_key)
        t.eq(reconcile.payload.round, 3)
      end
    end
  end,

  test_blocked_missing_decomposed_replay_decline_climbs_to_decompose_exhausted_without_seeded_timeout_markers = function()
    local comments = {
      state_comment("blocked", version, "2026-06-01T00:00:00Z"),
      m_builders.pr_link_marker(proposal_id, 7, "devloop-owner-repo-42-01HY", version, "dev"),
    }

    for sweep = 1, 3 do
      mock_repo()
      mock_issue_list("2026-06-03T01:03:0" .. tostring(sweep) .. "Z")
      mock_issue_state({ "fkst-dev:enabled", "fkst-dev:blocked" }, comments, "2026-06-03T01:03:0" .. tostring(sweep) .. "Z")
      mock_decompose_children()
      mock_empty_pr_list()

      local result = run_liveness_scan("liveness-blocked-missing-decomposed-stuck-sweep-" .. tostring(sweep))
      t.eq(result.exit_code, 0)
      t.eq(find_raise(result, "github-devloop-decompose.devloop_decompose"), nil)
      t.eq(find_raise(result, "devloop_timeout_reconcile"), nil)
      local comment = find_raise(result, "github-proxy.github_issue_comment_request")
      t.is_true(comment ~= nil)
      if sweep < 3 then
        t.is_true(comment.payload.body:find(conv_attempts.timeout_attempt_marker(proposal_id, version, "blocked", sweep, entity_lib.issue_source_ref(repo, 42)), 1, true) ~= nil)
        table.insert(comments, issue_comment(conv_attempts.timeout_attempt_marker(proposal_id, version, "blocked", sweep, entity_lib.issue_source_ref(repo, 42))))
      else
        t.is_true(comment.payload.body:find(conv_attempts.decompose_exhausted_marker(proposal_id, version, 3, entity_lib.issue_source_ref(repo, 42)), 1, true) ~= nil)
      end
    end
  end,
}
