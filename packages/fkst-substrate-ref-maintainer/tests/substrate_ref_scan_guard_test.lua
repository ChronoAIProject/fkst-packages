local fixtures = require("tests.substrate_ref_scan_helpers")
local t = fixtures.t
local core = fixtures.core
local gh_argv = fixtures.gh_argv
local current_pin = fixtures.current_pin
local target_sha = fixtures.target_sha
local older_valid_pin = fixtures.older_valid_pin
local base_sha = fixtures.base_sha
local old_branch_sha = fixtures.old_branch_sha
local pr_head_sha = fixtures.pr_head_sha
local pr_number = fixtures.pr_number
local substrate_repo = fixtures.substrate_repo
local opts = fixtures.opts
local run_scan = fixtures.run_scan
local shell_quote = fixtures.shell_quote
local ensure_dir = fixtures.ensure_dir
local mock_env = fixtures.mock_env
local mock_substrate_head = fixtures.mock_substrate_head
local mock_substrate_check_runs = fixtures.mock_substrate_check_runs
local mock_substrate_check_runs_green = fixtures.mock_substrate_check_runs_green
local mock_current_pin = fixtures.mock_current_pin
local mock_missing_pin = fixtures.mock_missing_pin
local mock_pin_read_failure = fixtures.mock_pin_read_failure
local mock_no_existing_pr = fixtures.mock_no_existing_pr
local mock_existing_pr = fixtures.mock_existing_pr
local mock_base_head = fixtures.mock_base_head
local mock_bump_branch_base_ancestry = fixtures.mock_bump_branch_base_ancestry
local mock_runtime_root = fixtures.mock_runtime_root
local mock_branch_missing = fixtures.mock_branch_missing
local mock_branch_present = fixtures.mock_branch_present
local mock_branch_present_at = fixtures.mock_branch_present_at
local mock_branch_pin = fixtures.mock_branch_pin
local mock_branch_pin_for_head = fixtures.mock_branch_pin_for_head
local mock_branch_pin_missing = fixtures.mock_branch_pin_missing
local mock_no_checked_out_bump_branch = fixtures.mock_no_checked_out_bump_branch
local mock_checked_out_bump_branch = fixtures.mock_checked_out_bump_branch
local mock_worktree_commands = fixtures.mock_worktree_commands
local mock_pr_create = fixtures.mock_pr_create
local json_string = fixtures.json_string
local render_comment = fixtures.render_comment
local mock_bump_pr_view = fixtures.mock_bump_pr_view
local mock_bump_diff = fixtures.mock_bump_diff
local mock_branch_head_for_merge = fixtures.mock_branch_head_for_merge
local mock_substrate_pin_ancestor = fixtures.mock_substrate_pin_ancestor
local mock_merge_success = fixtures.mock_merge_success
local count_calls = fixtures.count_calls
local count_git_write_calls = fixtures.count_git_write_calls
local count_raises = fixtures.count_raises
local eq_zero = fixtures.eq_zero

return {
  test_missing_substrate_ref_pin_is_benign_noop = function()
    mock_env("")
    mock_missing_pin()

    local result = run_scan(opts("substrate-no-pin"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("git show HEAD:.fkst/substrate-ref"), 1)
    t.eq(count_calls("git ls-remote"), 0)
    t.eq(count_calls("gh api"), 0)
    t.eq(count_calls("gh pr create"), 0)
    t.eq(count_git_write_calls(), 0)
  end,

  test_pin_read_git_failure_still_fails_closed = function()
    mock_env("")
    mock_pin_read_failure()

    local result = run_scan(opts("substrate-pin-read-failure"))

    t.eq(result.exit_code, 1)
    t.eq(count_calls("git ls-remote"), 0)
    t.eq(count_calls("gh api"), 0)
  end,

  test_current_pin_performs_no_github_or_git_writes = function()
    mock_env("")
    mock_current_pin(current_pin)
    mock_substrate_head(current_pin)

    local result = run_scan(opts("substrate-current"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api"), 0)
    t.eq(count_calls("gh pr create"), 0)
    t.eq(count_git_write_calls(), 0)
  end,

  test_dry_run_plans_singleton_bump_without_writes = function()
    mock_env("")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha)
    mock_no_existing_pr()

    local result = run_scan(opts("substrate-dry-run"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls(core.gh_pr_list_head_cmd("owner/repo", "chore/substrate-ref-bump")), 1)
    t.eq(count_calls("gh pr create"), 0)
    t.eq(count_git_write_calls(), 0)
  end,

  test_dry_run_holds_unpublishable_substrate_head_without_writes = function()
    mock_env("")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_no_existing_pr()
    mock_substrate_check_runs(target_sha, "in_progress", nil)

    local result = run_scan(opts("substrate-unpublishable-dry-run"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls(core.gh_commit_check_runs_cmd(substrate_repo, target_sha)), 1)
    t.eq(count_calls("gh pr create"), 0)
    t.eq(count_git_write_calls(), 0)
  end,

  test_real_mode_holds_unpublishable_substrate_head_before_branch_mutation = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_no_existing_pr()
    mock_substrate_check_runs(target_sha, "completed", "failure")

    local result = run_scan(opts("substrate-unpublishable-real", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls(core.gh_commit_check_runs_cmd(substrate_repo, target_sha)), 1)
    eq_zero(count_calls("git worktree add"), "worktree add for unpublishable target")
    eq_zero(count_calls("gh pr create"), "PR create for unpublishable target")
    eq_zero(count_calls("HEAD:refs/heads/chore/substrate-ref-bump"), "push for unpublishable target")
  end,

  -- The gh adapter signals a non-zero-exit command by THROWING a table that carries the
  -- command result; run_adapter unwraps it so run_gh can classify the failure itself.
  -- Without that unwrap the throw escapes as the generic "adapter-operation-failed",
  -- losing the narrow, greppable gh-command-failed class. Nothing observed this before.
  test_failed_check_runs_read_surfaces_the_gh_command_error_class = function()
    mock_env("")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_no_existing_pr()
    t.mock_command(core.gh_commit_check_runs_cmd(substrate_repo, target_sha), {
      stdout = "",
      stderr = "gh: check-runs read refused\n",
      exit_code = 1,
    })

    local result = run_scan(opts("substrate-check-runs-read-failure"))

    t.eq(result.exit_code, 1)
    local raised = tostring(result.error or "")
    t.eq(raised:find("gh-command-failed", 1, true) ~= nil, true)
    t.eq(raised:find("substrate upstream check-runs read", 1, true) ~= nil, true)
    t.eq(raised:find("gh: check-runs read refused", 1, true) ~= nil, true)
    t.eq(raised:find("adapter-operation-failed", 1, true), nil)
  end,

}
