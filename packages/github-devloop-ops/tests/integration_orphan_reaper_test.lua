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
  test_orphan_reaper_closes_managed_pr_when_parent_issue_is_closed = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({ 7 })
    mock_reaper_pr(proposal_id, 42, 7)
    mock_issue_view({}, "CLOSED")
    mock_pr_close()
    mock_pr_comment_write()
    mock_dashboard_issue_list()
    mock_dashboard_create()

    local result = run_observability(opts("observability-reap-closed-parent", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr comment 7 --repo owner/repo --body-file /tmp/fkst-github-devloop-reap-"), 1)
    t.eq(count_calls("gh pr close 7 --repo owner/repo"), 1)
    local input_path = command_body_file(first_call("gh pr comment 7 --repo owner/repo --body-file /tmp/fkst-github-devloop-reap-"))
    local written = file.read(input_path)
    t.is_true(written:find("Parent: #42", 1, true) ~= nil)
    t.is_true(written:find("Reason: Parent issue #42 is closed.", 1, true) ~= nil)
    t.is_true(written:find('orphan-reaped:v1 proposal="' .. proposal_id .. '" pr="7" reason="parent-closed"', 1, true) ~= nil)
  end,

  test_orphan_reaper_does_not_write_reaped_marker_before_close_succeeds = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({ 7 })
    mock_reaper_pr(proposal_id, 42, 7)
    mock_issue_view({}, "CLOSED")
    mock_pr_close_failure()

    local result = run_observability(opts("observability-reap-close-fails", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 1)
    t.eq(count_calls("gh pr close '7' --repo 'owner/repo'"), 1)
    t.eq(count_calls("gh pr comment"), 0)
  end,

  test_orphan_reaper_dry_run_does_not_close_closed_parent_pr_without_write = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({})
    mock_pr_list({ 7 })
    mock_reaper_pr(proposal_id, 42, 7)
    mock_issue_view({}, "CLOSED")

    local logs = capture_observability_logs()

    t.eq(count_calls("gh pr comment"), 0)
    t.eq(count_calls("gh pr close"), 0)
    t.is_true(table.concat(logs, "\n"):find("tag=REAP", 1, true) ~= nil)
    t.is_true(table.concat(logs, "\n"):find("action=dry-run", 1, true) ~= nil)
  end,

  test_orphan_reaper_skips_foreign_owned_parent_without_write = function()
    assert_orphan_reaper_skips_parent_owned_by({ assignees = { "human" }, author = "fkst-test-bot" })
  end,

  test_orphan_reaper_skips_unassigned_foreign_author_parent_without_write = function()
    assert_orphan_reaper_skips_parent_owned_by({ assignees = {}, author = "human" })
  end,

  test_orphan_reaper_leaves_managed_pr_when_parent_issue_is_open = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({ 7 })
    mock_reaper_pr(proposal_id, 42, 7, {
      render_comment(core.state_marker(proposal_id, "fixing", "v1/fix/11"), "fkst-test-bot"),
    })
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "fixing", "v1/fix/11"), "fkst-test-bot"),
    }, "OPEN")
    mock_dashboard_issue_list()
    mock_dashboard_create()

    local result = run_observability(opts("observability-reap-open-parent", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr comment"), 0)
    t.eq(count_calls("gh pr close"), 0)
  end,

  test_orphan_reaper_is_idempotent_when_reaped_marker_is_visible = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({ 7 })
    mock_reaper_pr(proposal_id, 42, 7, {
      render_comment(m_builders.orphan_reaped_marker(proposal_id, 7, "parent-closed"), "fkst-test-bot"),
    })
    mock_dashboard_issue_list()
    mock_dashboard_create()

    local result = run_observability(opts("observability-reap-idempotent", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr comment"), 0)
    t.eq(count_calls("gh pr close"), 0)
  end,

  test_orphan_reaper_closes_managed_pr_when_parent_is_decomposed_with_successors = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "v1/fix/12"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({ 7 })
    mock_reaper_pr(proposal_id, 42, 7, {
      render_comment(decompose_lib.decomposed_marker(proposal_id, version, 7, 2), "fkst-test-bot"),
      render_comment('<!-- fkst:github-proxy:issue-created:v1 dedup="decompose/' .. proposal_id .. '/' .. version .. '/1/aaa" issue="132" -->', "fkst-test-bot"),
      render_comment('<!-- fkst:github-proxy:issue-created:v1 dedup="decompose/' .. proposal_id .. '/' .. version .. '/2/bbb" issue="146" -->', "fkst-test-bot"),
    })
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "blocked", version), "fkst-test-bot"),
    }, "OPEN")
    mock_pr_close()
    mock_pr_comment_write()
    mock_dashboard_issue_list()
    mock_dashboard_create()

    local result = run_observability(opts("observability-reap-decomposed-parent", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr close '7' --repo 'owner/repo'"), 1)
    local input_path = command_body_file(first_call("gh pr comment 7 --repo owner/repo --body-file /tmp/fkst-github-devloop-reap-"))
    local written = file.read(input_path)
    t.is_true(written:find("Successors: #132, #146", 1, true) ~= nil)
    t.is_true(written:find('reason="parent-decomposed"', 1, true) ~= nil)
  end,

  test_orphan_reaper_waits_for_decomposed_successor_facts = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "v1/fix/12"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({ 7 })
    mock_reaper_pr(proposal_id, 42, 7, {
      render_comment(decompose_lib.decomposed_marker(proposal_id, version, 7, 2), "fkst-test-bot"),
      render_comment('<!-- fkst:github-proxy:issue-created:v1 dedup="decompose/' .. proposal_id .. '/' .. version .. '/1/aaa" issue="132" -->', "fkst-test-bot"),
    })
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "blocked", version), "fkst-test-bot"),
    }, "OPEN")
    mock_dashboard_issue_list()
    mock_dashboard_create()

    local result = run_observability(opts("observability-reap-decomposed-waits-successors", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr comment"), 0)
    t.eq(count_calls("gh pr close"), 0)
  end,

}
