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
  test_liveness_scan_skips_terminal_issue = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:merged" }, "OPEN", {
      core.state_marker(proposal_id, "merged", version),
    })
    mock_empty_pr_list()

    assert_no_entity_change(run_liveness_scan("liveness-scan-terminal"))
  end,

  test_liveness_scan_skips_issue_without_state = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {})
    mock_empty_pr_list()

    assert_no_entity_change(run_liveness_scan("liveness-scan-no-state"))
  end,

  test_liveness_scan_requeues_every_non_terminal_issue_marker_state = function()
    local issues = {}
    local expected = {}
    local live_defer = {}
    local terminal = {}
    local release_codex_runs = {}
    local number = 100
    local run_opts = opts("liveness-scan-non-terminal-issue-marker-conformance")
    for _, row in ipairs(core.restart_transition_table()) do
      number = number + 1
      local state = row.from_state
      table.insert(issues, {
        number = number,
        state = "open",
        updated_at = "2026-06-03T01:02:03Z",
      })
      local fresh_version = state == "implementing" and "ready/2999-01-01T00-00-00Z" or "2999-01-01T00-00-00Z"
      local proposal = base_ids.proposal_id(repo, number)
      local comments = { { body = h.state_comment(proposal, state, fresh_version), author_login = "fkst-test-bot", created_at = "2999-01-01T00:00:00Z" } }
      if state == "implementing" then table.insert(comments, { body = core.implement_attempt_marker(proposal, fresh_version, 1, tostring(now() - 60)), author_login = "fkst-test-bot", created_at = "2999-01-01T00:00:00Z" }) end
      mock_issue_state_number(number, { "fkst-dev:enabled", devloop_state.state_label(state) }, "OPEN", comments)
      if row.terminal == false then
        if row.liveness_contract
          and row.liveness_contract.real_execution
          and row.liveness_contract.real_execution.primitive == "fkst.codex_runs" then
          live_defer[number] = state
          table.insert(release_codex_runs, codex_status.seed_role_codex_run(
            run_opts, row.liveness_contract.real_execution.match.role, proposal, fresh_version
          ))
        else
          expected[number] = state
        end
      else
        terminal[number] = state
      end
    end
    mock_repo()
    mock_issue_list(issues)
    mock_empty_pr_list()

    local result = run_liveness_scan("liveness-scan-non-terminal-issue-marker-conformance", run_opts)
    for _, release_codex_run in ipairs(release_codex_runs) do
      release_codex_run()
    end
    t.eq(result.exit_code, 0)
    for issue_number, state in pairs(expected) do
      t.eq(has_liveness_action_for_proposal(result, base_ids.proposal_id(repo, issue_number)), true, "non-terminal issue marker state not sweep-reachable: " .. tostring(state))
    end
    for issue_number, state in pairs(live_defer) do
      local target_proposal = base_ids.proposal_id(repo, issue_number)
      t.eq(find_raise(result.raises, "devloop_timeout_reconcile", function(payload)
        return payload.proposal_id == target_proposal
      end), nil, "live codex-run state should not timeout-reconcile: " .. tostring(state))
      t.eq(find_raise(result.raises, "devloop_ready", function(payload)
        return payload.proposal_id == target_proposal
      end), nil, "live codex-run state should not respawn implement: " .. tostring(state))
      t.eq(find_raise(result.raises, "devloop_consensus_request", function(payload)
        return payload.proposal_id == target_proposal
      end), nil, "live codex-run state should not respawn consensus: " .. tostring(state))
    end
    local raised = entity_change_issue_numbers(result)
    for issue_number, state in pairs(terminal) do
      t.eq(raised[issue_number], nil, "terminal issue marker state was requeued: " .. tostring(state))
    end
  end,

  test_liveness_scan_requeues_ready_dependency_hold = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready", "fkst-dev:blocked-on-dependency" }, "OPEN", {
      h.projected_state_comment(proposal_id, "dependency_wait", version),
      core.dependency_wait_marker(proposal_id, version, { 7 }),
    })
    mock_empty_pr_list()

    local result = run_liveness_scan("liveness-scan-ready-dependency-hold")
    t.eq(result.exit_code, 0)
    local raised = find_raise(result.raises, ISSUE_REDRIVE_QUEUE)
    t.is_true(raised ~= nil)
    t.eq(raised.payload.type, "issue")
    t.eq(raised.payload.source, "liveness-scan")
    t.is_true(tostring(raised.payload.dedup_key):find("liveness%-scan", 1) ~= nil)
  end,

  test_liveness_scan_caps_before_fresh_entity_views = function()
    local items = {}
    for number = 1, 101 do
      table.insert(items, { number = number, state = "open", updated_at = "2026-06-03T01:02:03Z" })
    end
    mock_repo()
    mock_issue_list(items)
    mock_empty_pr_list()
    for number = 1, 101 do
      mock_issue_state_number(number, { "fkst-dev:enabled", "fkst-dev:merged" }, "OPEN", {
        core.state_marker(base_ids.proposal_id(repo, number), "merged", "v-" .. tostring(number)),
      })
    end

    local result = run_liveness_scan("liveness-scan-cap-before-views")
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, ISSUE_REDRIVE_QUEUE), nil)
    local views = 0
    for _, call in ipairs(t.command_calls()) do
      if issue_rest_view_number(call.rendered) ~= nil then
        views = views + 1
      end
    end
    t.eq(views, 100)
  end,

  test_liveness_scan_uses_cursor_first_batch_on_large_board = function()
    local items = {}
    for number = 1, 101 do
      table.insert(items, { number = number, state = "open", updated_at = "2026-06-03T01:02:03Z" })
    end
    mock_repo()
    mock_issue_list(items)
    mock_empty_pr_list()
    for number = 1, 101 do
      mock_issue_state_number(number, { "fkst-dev:enabled", "fkst-dev:merged" }, "OPEN", {
        core.state_marker(base_ids.proposal_id(repo, number), "merged", "v-" .. tostring(number)),
      })
    end

    local tick = "2026-06-03T01:32:04Z"
    local result = run_liveness_scan_at("liveness-scan-rotates-large-board", tick)
    t.eq(result.exit_code, 0)

    local viewed = {}
    for _, call in ipairs(t.command_calls()) do
      local issue_number = issue_rest_view_number(call.rendered)
      if issue_number ~= nil then
        viewed[tonumber(issue_number)] = true
      end
    end
    t.eq(viewed[1], true)
    t.eq(viewed[100], true)
    t.eq(viewed[101], nil)
  end,

  test_liveness_scan_cursor_covers_large_board_across_k_ticks = function()
    local items = {}
    for number = 1, 250 do
      table.insert(items, { number = number, state = "open", updated_at = "2026-06-03T01:02:03Z" })
    end

    local viewed = {}
    local run_opts = opts("liveness-scan-cursor-k")
    for tick = 1, 3 do
      mock_repo()
      mock_issue_list(items)
      mock_empty_pr_list()
      for number = 1, 250 do
        mock_issue_state_number(number, { "fkst-dev:enabled", "fkst-dev:merged" }, "OPEN", {
          core.state_marker(base_ids.proposal_id(repo, number), "merged", "v-" .. tostring(number)),
        })
      end

      local result = run_liveness_scan_at("liveness-scan-cursor-k", tostring(tick), run_opts)
      t.eq(result.exit_code, 0)

      for _, call in ipairs(t.command_calls()) do
        local issue_number = issue_rest_view_number(call.rendered)
        if issue_number ~= nil then
          viewed[tonumber(issue_number)] = true
        end
      end
    end

    for number = 1, 250 do
      t.eq(viewed[number], true)
    end
  end,

  test_liveness_scan_defers_slow_issue_view_without_retry_failure = function()
    mock_repo()
    mock_issue_list({ { number = 42, state = "open", updated_at = "2026-06-03T01:02:03Z" } })
    mock_empty_pr_list()
    t.mock_command("gh api 'repos/owner/repo/issues/42'", {
      stdout = "",
      stderr = "timed out",
      exit_code = 124,
    })

    local result = run_liveness_scan("liveness-scan-view-timeout-deferred")
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, ISSUE_REDRIVE_QUEUE), nil)
  end,
}
