local fixtures = require("tests.observability_test_helpers")
local h = fixtures.h
local t = fixtures.t
local core = fixtures.core
local entity_read_mocks = fixtures.entity_read_mocks
local gh_argv = fixtures.gh_argv
local decompose_lib = fixtures.decompose_lib
local m_builders = fixtures.m_builders
local opts = fixtures.opts
local run_observability = fixtures.run_observability
local mock_env = fixtures.mock_env
local encode_json_string = fixtures.encode_json_string
local observe_issue_list_command = fixtures.observe_issue_list_command
local observe_issue_list_first_command = fixtures.observe_issue_list_first_command
local observe_pr_list_command = fixtures.observe_pr_list_command
local observe_pr_list_first_command = fixtures.observe_pr_list_first_command
local render_comment = fixtures.render_comment
local wait_marker = fixtures.wait_marker
local mock_all_issue_lists = fixtures.mock_all_issue_lists
local mock_pr_list = fixtures.mock_pr_list
local mock_issue_view = fixtures.mock_issue_view
local mock_pr_view = fixtures.mock_pr_view
local count_calls = fixtures.count_calls
local has_call = fixtures.has_call
local first_call = fixtures.first_call
local observability_pipeline = fixtures.observability_pipeline
local run_observability_pipeline = fixtures.run_observability_pipeline
local capture_observability_logs = fixtures.capture_observability_logs
local try_capture_observability_logs = fixtures.try_capture_observability_logs
local summary_log = fixtures.summary_log
local stall_suspect_logs = fixtures.stall_suspect_logs
local version_minutes_ago = fixtures.version_minutes_ago
local dashboard_hash = fixtures.dashboard_hash
local command_input_path = fixtures.command_input_path
local command_body_file = fixtures.command_body_file
local dashboard_issue_list_command = fixtures.dashboard_issue_list_command
local dashboard_label_get_command = fixtures.dashboard_label_get_command
local dashboard_label_create_command = fixtures.dashboard_label_create_command
local devloop_branch = fixtures.devloop_branch
local mock_reaper_pr = fixtures.mock_reaper_pr
local mock_pr_comment_write = fixtures.mock_pr_comment_write
local mock_pr_close = fixtures.mock_pr_close
local mock_pr_close_failure = fixtures.mock_pr_close_failure
local mock_dashboard_label_exists = fixtures.mock_dashboard_label_exists
local mock_dashboard_issue_list = fixtures.mock_dashboard_issue_list
local mock_dashboard_create = fixtures.mock_dashboard_create
local mock_dashboard_patch = fixtures.mock_dashboard_patch
local assert_orphan_reaper_skips_parent_owned_by = fixtures.assert_orphan_reaper_skips_parent_owned_by

return {
  test_summary_logs_all_known_states_with_zero_defaults = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(h.projected_state_comment(proposal_id, "ready", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })

    local summary = summary_log(capture_observability_logs())

    t.is_true(summary ~= nil)
    t.is_true(summary:find("total=1", 1, true) ~= nil)
    for _, state in ipairs(core.lifecycle_state_order()) do
      local expected = state == "ready" and 1 or 0
      t.is_true(summary:find(state .. "=" .. tostring(expected), 1, true) ~= nil)
    end
    t.is_true(summary:find("unmanaged=", 1, true) == nil)
  end,

  test_logs_issue_phase_state_from_trusted_marker_and_ignores_forged_marker = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "blocked", "2099-01-01T00-00-00Z"), "mallory"),
      render_comment(h.projected_state_comment(proposal_id, "ready", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })

    local result = run_observability()

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    local observed = core.observe_entity_log_line(proposal_id, {
      state = "ready",
      version = "2026-06-03T01-02-03Z",
      marker_source = "issue",
      marker_created_at = "2026-06-03T01:02:03Z",
    })
    t.is_true(observed:find("tag=OBSERVE_ENTITY", 1, true) ~= nil)
    t.is_true(observed:find("state=ready", 1, true) ~= nil)
    t.is_true(observed:find("marker_source=issue", 1, true) ~= nil)
  end,

  test_observe_summary_counts_only_open_list_entities = function()
    local open_proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({
      { number = 42, state = "open" },
      { number = 43, state = "closed" },
    })
    mock_pr_list({
      { number = 8, state = "closed" },
    })
    mock_issue_view({
      render_comment(h.projected_state_comment(open_proposal_id, "ready", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })

    local summary = summary_log(capture_observability_logs())

    t.is_true(summary ~= nil)
    t.is_true(summary:find("total=1", 1, true) ~= nil)
    t.is_true(summary:find("ready=1", 1, true) ~= nil)
    t.is_true(summary:find("closed", 1, true) == nil)
    t.is_true(has_call(observe_issue_list_first_command(core._enabled_label)))
  end,

  test_pr_phase_comment_stream_wins_over_stale_issue_pr_open = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local impl_version = "2026-06-03T01-02-03Z"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "pr-open", impl_version), "fkst-test-bot", "2026-06-03T01:02:03Z"),
      render_comment(m_builders.pr_link_marker(proposal_id, 7, "devloop-owner-repo-42", impl_version, "integration/dev")),
    })
    mock_pr_view({
      render_comment(m_builders.pr_origin_marker(proposal_id, "42", "devloop-owner-repo-42", impl_version, "integration/dev")),
      render_comment(core.state_marker(proposal_id, "reviewing", impl_version), "fkst-test-bot", "2026-06-03T02:03:04Z"),
    })

    local logs = table.concat(capture_observability_logs(), "\n")

    t.is_true(logs:find("proposal=" .. proposal_id, 1, true) ~= nil)
    t.is_true(logs:find("state=reviewing", 1, true) ~= nil)
    t.is_true(logs:find("marker_source=pr-comment", 1, true) ~= nil)
    t.is_true(logs:find("pr=7", 1, true) ~= nil)
  end,

  test_pr_enumeration_reads_origin_fact_when_issue_side_is_absent = function()
    local proposal_id = "github-devloop/issue/owner/repo/43"
    mock_env()
    mock_all_issue_lists({})
    mock_pr_list({ 8 })
    mock_pr_view({
      render_comment(m_builders.pr_origin_marker(proposal_id, "43", "devloop-owner-repo-43", "v1", "integration/dev")),
      render_comment(core.state_marker(proposal_id, "merge-ready", "v1"), "fkst-test-bot", "2026-06-03T03:03:04Z"),
    }, { number = 8, head_ref_name = "devloop-owner-repo-43" })

    local logs = table.concat(capture_observability_logs(), "\n")

    t.is_true(logs:find("state=merge-ready", 1, true) ~= nil)
    t.is_true(logs:find("marker_source=pr-comment", 1, true) ~= nil)
    t.is_true(logs:find("pr=8", 1, true) ~= nil)
  end,

  test_stall_suspect_logs_once_when_entity_exceeds_state_threshold = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = version_minutes_ago(31)
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "thinking", version), "fkst-test-bot"),
    })

    local logs = stall_suspect_logs(capture_observability_logs())

    t.eq(#logs, 1)
    t.is_true(logs[1]:find("github-devloop", 1, true) ~= nil)
    t.is_true(logs[1]:find("dept=observability", 1, true) ~= nil)
    t.is_true(logs[1]:find("proposal=" .. proposal_id, 1, true) ~= nil)
    t.is_true(logs[1]:find("state=thinking", 1, true) ~= nil)
    t.is_true(logs[1]:find("threshold_minutes=30", 1, true) ~= nil)
  end,

  test_stall_suspect_does_not_log_under_threshold = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "reviewing", version_minutes_ago(60)), "fkst-test-bot"),
    })

    local logs = stall_suspect_logs(capture_observability_logs())

    t.eq(#logs, 0)
  end,

  test_stall_suspect_excludes_dependency_held_ready_entities = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = version_minutes_ago(31)
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(h.projected_state_comment(proposal_id, "ready", version), "fkst-test-bot"),
      render_comment(wait_marker(proposal_id, version, { 7 }), "fkst-test-bot"),
    })

    local logs = stall_suspect_logs(capture_observability_logs())

    t.eq(#logs, 0)
  end,

  test_stall_suspect_never_logs_terminal_states = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "blocked", version_minutes_ago(1000)), "fkst-test-bot"),
    })

    local logs = stall_suspect_logs(capture_observability_logs())

    t.eq(#logs, 0)
  end,

  test_fail_closed_when_bot_login_is_unset = function()
    mock_env("")
    local result = run_observability(opts("observability-no-bot", { FKST_GITHUB_BOT_LOGIN = "" }))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh api --paginate --slurp"), 0)
  end,

  test_enumeration_uses_explicit_bounded_pages = function()
    mock_env()
    mock_all_issue_lists({})
    mock_pr_list({})

    local result = run_observability()

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.is_true(has_call(observe_issue_list_first_command(core._enabled_label)))
    t.is_true(has_call(observe_pr_list_first_command()))
    t.eq(count_calls("gh api --paginate --slurp 'repos/owner/repo/issues?state=open&labels=fkst-dev%3Aenabled&per_page=100'"), 0)
    t.eq(count_calls("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&per_page=100'"), 0)
  end,

  test_observability_caps_total_entity_views_and_logs_deferred_work = function()
    local issues = {}
    local prs = {}
    for i = 1, 30 do
      table.insert(issues, i)
      table.insert(prs, i + 100)
    end
    mock_env()
    mock_all_issue_lists(issues)
    mock_pr_list(prs)
    local event = {
      queue = "devloop_observe_tick",
      payload = { schema = "github-devloop.observe-tick.v1", cursor = "0", tick = "0" },
    }
    local candidates = core.observability_entity_candidates(issues, prs, core.observability_rotation_seed(event), 25)
    for _, candidate in ipairs(candidates) do
      if candidate.kind == "issue" then
        mock_issue_view({
          render_comment(h.projected_state_comment("github-devloop/issue/owner/repo/" .. tostring(candidate.number), "ready", "2026-06-03T01-02-03Z"), "fkst-test-bot"),
        }, nil, { number = candidate.number })
      else
        mock_pr_view({}, { number = candidate.number })
      end
    end

    local logs = capture_observability_logs(event)

    local body = table.concat(logs, "\n")
    t.is_true(body:find("tag=OBSERVE_DEFERRED", 1, true) ~= nil)
    t.is_true(body:find("entity_cap=25", 1, true) ~= nil)
    t.is_true(body:find("listed_issues=30", 1, true) ~= nil)
    t.is_true(body:find("listed_prs=30", 1, true) ~= nil)
  end,

  test_observability_gh_calls_have_short_timeouts_and_fail_closed = function()
    local seen_timeout = nil
    local ok, err = pcall(function()
      core.observability_run_cmd("gh issue list", core.observability_limits(), now() + 90, "gh observability issue list", function(spec)
        seen_timeout = spec.timeout
        return { stdout = "", stderr = "timed out", exit_code = 124 }
      end)
    end)

    t.eq(ok, false)
    t.eq(seen_timeout, 10)
    t.is_true(tostring(err):find("gh observability issue list failed", 1, true) ~= nil)
  end,

}
