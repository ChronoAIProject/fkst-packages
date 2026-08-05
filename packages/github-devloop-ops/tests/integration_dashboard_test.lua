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
  test_dashboard_dry_run_renders_board_without_github_write = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "ready", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })

    local logs = capture_observability_logs()
    local body = table.concat(logs, "\n")

    t.is_true(body:find("tag=DASHBOARD_DRY_RUN", 1, true) ~= nil)
    t.is_true(body:find("# fkst-dev board", 1, true) ~= nil)
    t.is_true(body:find("## Now working", 1, true) ~= nil)
    t.is_true(body:find("## Board by state", 1, true) ~= nil)
    t.is_true(body:find("#42 Observed issue - ready", 1, true) ~= nil)
    t.is_true(body:find("fkst:dashboard:v1", 1, true) ~= nil)
    t.eq(count_calls("gh api --method POST"), 0)
    t.eq(count_calls("gh api --method PATCH"), 0)
  end,

  test_dashboard_write_creates_single_marker_issue_when_absent = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "implementing", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })
    mock_dashboard_issue_list()
    mock_dashboard_create()

    local result = run_observability(opts("observability-dashboard-create", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls(dashboard_label_get_command()), 1)
    t.eq(count_calls("gh api --method POST 'repos/owner/repo/issues'"), 1)
    t.eq(count_calls("gh api --method PATCH"), 0)
    local input_path = command_input_path(first_call("gh api --method POST 'repos/owner/repo/issues'"))
    t.is_true(input_path ~= nil)
    t.is_true(input_path:find("/tmp/fkst-github-devloop-dashboard-owner-repo-", 1, true) == 1)
    t.is_true(input_path ~= "/tmp/fkst-github-devloop-dashboard-owner-repo.json")
    local written = file.read(input_path)
    t.is_true(written:find('"title":"fkst-dev board"', 1, true) ~= nil)
    t.is_true(written:find('"labels":["fkst-dashboard"]', 1, true) ~= nil)
    t.is_true(written:find("fkst:dashboard:v1", 1, true) ~= nil)
    t.is_true(written:find("implementing", 1, true) ~= nil)
    t.eq(count_calls("--search"), 0)
  end,

  test_dashboard_write_updates_existing_trusted_issue_when_hash_changes = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "reviewing", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })
    mock_dashboard_issue_list('[[{"number":99,"title":"fkst-dev board","user":{"login":"fkst-test-bot"},"body":"old\\n<!-- fkst:dashboard:v1 version=\\"2026-06-01T00:00:00Z\\" hash=\\"old\\" generated_at=\\"2026-06-01T00:00:00Z\\" -->"}]]\n')
    t.mock_command("gh api --method GET --include 'repos/owner/repo/issues/99'", {
      stdout = 'HTTP/2.0 200 OK\netag: W/"dashboard-old-etag"\n\n{"number":99,"title":"fkst-dev board","author":{"login":"fkst-test-bot"},"body":"old\\n<!-- fkst:dashboard:v1 version=\\"2026-06-01T00:00:00Z\\" hash=\\"old\\" generated_at=\\"2026-06-01T00:00:00Z\\" -->"}\n',
      stderr = "",
      exit_code = 0,
    })
    mock_dashboard_patch()

    local result = run_observability(opts("observability-dashboard-update", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --method POST"), 0)
    t.eq(count_calls("If-Match"), 0)
    t.eq(count_calls("gh api --method PATCH 'repos/owner/repo/issues/99' --input"), 1)
    local input_path = command_input_path(first_call("gh api --method PATCH 'repos/owner/repo/issues/99' --input"))
    t.is_true(input_path ~= nil)
    t.is_true(input_path:find("/tmp/fkst-github-devloop-dashboard-owner-repo-", 1, true) == 1)
    t.is_true(input_path ~= "/tmp/fkst-github-devloop-dashboard-owner-repo.json")
  end,

  test_dashboard_write_skips_update_when_version_cas_mismatches = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "reviewing", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })
    mock_dashboard_issue_list('[[{"number":99,"title":"fkst-dev board","user":{"login":"fkst-test-bot"},"body":"old\\n<!-- fkst:dashboard:v1 version=\\"2026-06-01T00:00:00Z\\" hash=\\"old\\" generated_at=\\"2026-06-01T00:00:00Z\\" -->"}]]\n')
    t.mock_command("gh api --method GET --include 'repos/owner/repo/issues/99'", {
      stdout = 'HTTP/2.0 200 OK\netag: "dashboard-newer-etag"\n\n{"number":99,"title":"fkst-dev board","author":{"login":"fkst-test-bot"},"body":"newer\\n<!-- fkst:dashboard:v1 version=\\"2026-06-01T00:01:00Z\\" hash=\\"newer\\" generated_at=\\"2026-06-01T00:01:00Z\\" -->"}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = run_observability(opts("observability-dashboard-cas-mismatch", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --method POST"), 0)
    t.eq(count_calls("gh api --method PATCH"), 0)
    t.eq(count_calls(dashboard_issue_list_command()), 1)
    t.eq(count_calls("gh api --method GET --include 'repos/owner/repo/issues/99'"), 1)
  end,

  test_dashboard_write_bootstraps_missing_dashboard_label_before_create = function()
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({})
    t.mock_command(dashboard_label_get_command(), {
      stdout = "",
      stderr = "HTTP 404: Not Found\n",
      exit_code = 1,
    })
    t.mock_command(dashboard_label_create_command(), {
      stdout = '{"name":"fkst-dashboard"}\n',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(dashboard_issue_list_command(), {
      stdout = "[[]]\n",
      stderr = "",
      exit_code = 0,
    })
    mock_dashboard_create()

    local result = run_observability(opts("observability-dashboard-label-bootstrap", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls(dashboard_label_get_command()), 1)
    t.eq(count_calls(dashboard_label_create_command()), 1)
    t.eq(count_calls("gh api --method POST 'repos/owner/repo/issues'"), 1)
  end,

  test_dashboard_write_skips_update_when_patch_precondition_fails = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "reviewing", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })
    mock_dashboard_issue_list('[[{"number":99,"title":"fkst-dev board","user":{"login":"fkst-test-bot"},"body":"old\\n<!-- fkst:dashboard:v1 version=\\"2026-06-01T00:00:00Z\\" hash=\\"old\\" generated_at=\\"2026-06-01T00:00:00Z\\" -->"}]]\n')
    t.mock_command("gh api --method GET --include 'repos/owner/repo/issues/99'", {
      stdout = 'HTTP/2.0 200 OK\netag: "dashboard-old-etag"\n\n{"number":99,"title":"fkst-dev board","author":{"login":"fkst-test-bot"},"body":"old\\n<!-- fkst:dashboard:v1 version=\\"2026-06-01T00:00:00Z\\" hash=\\"old\\" generated_at=\\"2026-06-01T00:00:00Z\\" -->"}\n',
      stderr = "",
      exit_code = 0,
    })
    mock_dashboard_patch("", "HTTP 412: Precondition Failed\n", 1)

    local result = run_observability(opts("observability-dashboard-patch-precondition", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --method POST"), 0)
    t.eq(count_calls("If-Match"), 0)
    t.eq(count_calls("gh api --method PATCH 'repos/owner/repo/issues/99' --input"), 1)
  end,

  test_dashboard_write_skips_stale_snapshot_when_current_version_is_newer = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "reviewing", "2026-06-03T01-02-03Z"), "fkst-test-bot", "2026-06-03T01:02:03Z"),
    })
    mock_dashboard_issue_list('[[{"number":99,"title":"fkst-dev board","user":{"login":"fkst-test-bot"},"body":"newer\\n<!-- fkst:dashboard:v1 version=\\"2099-01-01T00:00:00Z\\" hash=\\"newer\\" generated_at=\\"2099-01-01T00:00:00Z\\" -->"}]]\n')

    local result = run_observability(opts("observability-dashboard-stale", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --method POST"), 0)
    t.eq(count_calls("gh api --method PATCH"), 0)
    t.eq(count_calls(dashboard_issue_list_command()), 1)
  end,

  test_dashboard_write_skips_existing_trusted_issue_when_hash_matches = function()
    mock_env("fkst-test-bot", "1")
    local rendered = core.render_observability_dashboard({
      entities = {},
      counts = {},
      stalls = {},
      now_seconds = now(),
    })
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({})
    mock_dashboard_issue_list('[[{"number":99,"title":"fkst-dev board","user":{"login":"fkst-test-bot"},"body":"<!-- fkst:dashboard:v1 version=\\"2026-06-01T00:00:00Z\\" hash=\\"' .. dashboard_hash(rendered.body) .. '\\" generated_at=\\"2026-06-01T00:00:00Z\\" -->"}]]\n')

    local result = run_observability(opts("observability-dashboard-unchanged", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --method POST"), 0)
    t.eq(count_calls("gh api --method PATCH"), 0)
    t.is_true(first_call(dashboard_issue_list_command()) ~= nil)
  end,

  test_dashboard_locator_failure_logs_auth_mode_and_http_status = function()
    mock_env("fkst-test-bot", "1")
    mock_all_issue_lists({})
    mock_pr_list({})
    mock_dashboard_issue_list("", 1, "GraphQL: API rate limit already exceeded (HTTP 403)\n")

    local ok, logs = try_capture_observability_logs()

    t.eq(ok, false)
    t.eq(count_calls(dashboard_issue_list_command()), 1)
    t.eq(count_calls("--search"), 0)
    local body = table.concat(logs, "\n")
    t.is_true(body:find("tag=DASHBOARD_LOCATOR_FAILED", 1, true) ~= nil)
    t.is_true(body:find("locator=label-list", 1, true) ~= nil)
    t.is_true(body:find("auth_mode=gh-auth", 1, true) ~= nil)
    t.is_true(body:find("http_status=403", 1, true) ~= nil)
  end,
}
