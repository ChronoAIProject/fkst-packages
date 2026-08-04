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
  test_real_mode_creates_single_bump_pr_for_new_dev_head = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha, 3)
    mock_no_existing_pr()
    mock_branch_missing()
    mock_base_head()
    mock_runtime_root("substrate-create")
    mock_no_checked_out_bump_branch()
    mock_worktree_commands("substrate-create", false)
    mock_pr_create()
    mock_bump_pr_view()
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)
    mock_merge_success()

    local result = run_scan(opts("substrate-create", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr create"), 1)
    t.eq(count_calls("HEAD:refs/heads/chore/substrate-ref-bump"), 1)
    t.eq(count_calls("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'"), 1)
    local audit_raise = result.raises[1]
    t.eq(audit_raise.queue, "github-proxy.github_pr_comment_request")
    t.eq(audit_raise.payload.pr_number, pr_number)
    t.is_true(audit_raise.payload.body:find("github-devloop substrate-ref deterministic merge audit", 1, true) ~= nil)
    t.is_true(audit_raise.payload.body:find("fkst:github-devloop:substrate-ref-merge:v1", 1, true) ~= nil)
    t.is_true(audit_raise.payload.body:find('target_sha="' .. target_sha .. '"', 1, true) ~= nil)
    eq_zero(count_raises(result, "github-proxy.github_issue_create_request"), "create raises after new bump")
    eq_zero(count_raises(result, "github-proxy.github_issue_label_request"), "label raises after new bump")
  end,

  test_real_mode_merges_existing_green_bump_pr_with_own_valid_pin_before_repinning = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(older_valid_pin, 2)
    mock_existing_pr()
    mock_bump_pr_view()
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, older_valid_pin)
    mock_substrate_pin_ancestor(older_valid_pin)
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, older_valid_pin)
    mock_substrate_pin_ancestor(older_valid_pin)
    mock_merge_success()

    local result = run_scan(opts("substrate-update", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    eq_zero(count_calls("git worktree add"), "worktree add for valid existing bump")
    eq_zero(count_calls("git worktree remove --force"), "worktree remove for valid existing bump")
    eq_zero(count_calls("gh pr create"), "PR create for valid existing bump")
    eq_zero(count_calls("--force-with-lease=refs/heads/chore/substrate-ref-bump:" .. old_branch_sha), "push lease for valid existing bump")
    t.eq(count_calls("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'"), 1)
    t.eq(result.raises[1].queue, "github-proxy.github_pr_comment_request")
    t.is_true(result.raises[1].payload.body:find("substrate-ref-merge:v1", 1, true) ~= nil)
    eq_zero(count_raises(result, "github-proxy.github_issue_create_request"), "create raises after valid existing bump")
    eq_zero(count_raises(result, "github-proxy.github_issue_label_request"), "label raises after valid existing bump")
  end,

  test_real_mode_rechecks_pr_under_lock_before_update = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha, 2)
    mock_existing_pr()
    mock_bump_pr_view()
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)
    mock_merge_success()

    local result = run_scan(opts("substrate-recheck", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls(core.gh_pr_list_head_cmd("owner/repo", "chore/substrate-ref-bump")), 1)
    eq_zero(count_calls("gh pr create"), "PR create during recheck")
    eq_zero(count_calls(" push origin HEAD:refs/heads/'chore/substrate-ref-bump'"), "quoted push during recheck")
    eq_zero(count_calls("git worktree add"), "worktree add during recheck")
    eq_zero(count_calls("git worktree remove --force"), "worktree remove during recheck")
    t.eq(count_calls("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'"), 1)
    t.eq(result.raises[1].queue, "github-proxy.github_pr_comment_request")
    eq_zero(count_raises(result, "github-proxy.github_issue_create_request"), "create raises during recheck")
    eq_zero(count_raises(result, "github-proxy.github_issue_label_request"), "label raises during recheck")
  end,

  test_real_mode_merges_existing_green_bump_pr_before_checking_already_current_branch = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha, 2)
    mock_existing_pr()
    mock_bump_pr_view()
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)
    mock_merge_success()

    local result = run_scan(opts("substrate-already-current", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    eq_zero(count_calls("gh pr create"), "PR create before already-current merge")
    eq_zero(count_calls("git worktree add"), "worktree add before already-current merge")
    eq_zero(count_calls("git worktree remove --force"), "worktree remove before already-current merge")
    eq_zero(count_calls("git push"), "git push before already-current merge")
    t.eq(count_calls("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'"), 1)
    t.eq(result.raises[1].queue, "github-proxy.github_pr_comment_request")
  end,

  test_real_mode_holds_existing_bump_pr_when_diff_is_not_exact_pin_file = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha)
    mock_existing_pr()
    mock_branch_present()
    mock_branch_pin(target_sha)
    mock_base_head()
    mock_bump_branch_base_ancestry(0)
    mock_bump_pr_view()
    mock_bump_diff(".fkst/substrate-ref\nREADME.md")

    local result = run_scan(opts("substrate-unexpected-diff", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    eq_zero(count_calls("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'"), "merge call for unexpected diff")
    eq_zero(count_raises(result, "github-proxy.github_pr_comment_request"), "comment raises for unexpected diff")
  end,

  test_real_mode_repins_existing_bump_pr_when_pin_is_not_substrate_dev_ancestor = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha, 2)
    mock_existing_pr()
    mock_branch_present()
    mock_bump_pr_view()
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, current_pin)
    mock_substrate_pin_ancestor(current_pin, 1)
    mock_branch_present()
    mock_branch_pin_missing()
    mock_base_head()
    mock_runtime_root("substrate-pin-mismatch")
    mock_no_checked_out_bump_branch()
    mock_worktree_commands("substrate-pin-mismatch", true, old_branch_sha)
    mock_existing_pr()
    mock_bump_pr_view(nil, {
      rollup = '[{"name":"ci","status":"IN_PROGRESS","conclusion":""}]',
    })
    mock_bump_diff()
    mock_branch_present_at(pr_head_sha)
    mock_branch_pin_for_head(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)

    local result = run_scan(opts("substrate-pin-mismatch", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("--force-with-lease=refs/heads/chore/substrate-ref-bump:" .. old_branch_sha), 1)
    eq_zero(count_calls("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'"), "merge call after repin")
    eq_zero(count_raises(result, "github-proxy.github_pr_comment_request"), "comment raises after repin")
  end,

  test_real_mode_holds_existing_bump_pr_when_ci_is_not_green = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha, 2)
    mock_existing_pr()
    mock_branch_present()
    mock_branch_pin(target_sha)
    mock_base_head()
    mock_bump_branch_base_ancestry(0)
    mock_bump_pr_view(nil, {
      rollup = '[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]',
    })
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)
    mock_bump_pr_view(nil, {
      rollup = '[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]',
    })
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)

    local result = run_scan(opts("substrate-ci-red", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    eq_zero(count_calls("gh pr merge"), "merge call for red CI")
    eq_zero(count_raises(result, "github-proxy.github_pr_comment_request"), "comment raises for red CI")
  end,

  test_real_mode_refreshes_existing_bump_branch_when_pin_matches_but_base_is_stale = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha)
    mock_existing_pr()
    mock_branch_present()
    mock_branch_pin(target_sha)
    mock_bump_pr_view(nil, {
      rollup = '[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]',
    })
    mock_bump_diff(".fkst/substrate-ref\nREADME.md")
    mock_base_head()
    mock_bump_branch_base_ancestry(1)
    mock_runtime_root("substrate-stale-base")
    mock_no_checked_out_bump_branch()
    mock_worktree_commands("substrate-stale-base", true, old_branch_sha)
    mock_existing_pr()
    mock_bump_pr_view(nil, {
      rollup = '[{"name":"ci","status":"IN_PROGRESS","conclusion":""}]',
    })
    mock_bump_diff(".fkst/substrate-ref\nREADME.md")

    local result = run_scan(opts("substrate-stale-base", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("git merge-base --is-ancestor " .. base_sha .. " " .. old_branch_sha), 1)
    t.eq(count_calls("git worktree add -B chore/substrate-ref-bump"), 1)
    t.eq(count_calls("--force-with-lease=refs/heads/chore/substrate-ref-bump:" .. old_branch_sha), 1)
    eq_zero(count_calls("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'"), "merge call after stale-base refresh")
    eq_zero(count_raises(result, "github-proxy.github_pr_comment_request"), "comment raises after stale-base refresh")
  end,

  test_real_mode_removes_stale_checked_out_bump_branch_worktree_before_update = function()
    mock_env("1")
    mock_current_pin(current_pin)
    mock_substrate_head(target_sha)
    mock_substrate_check_runs_green(target_sha, 2)
    mock_existing_pr()
    mock_branch_present()
    mock_bump_pr_view()
    mock_bump_diff()
    mock_branch_head_for_merge(pr_head_sha, current_pin)
    mock_substrate_pin_ancestor(current_pin, 1)
    mock_branch_present()
    mock_branch_pin_missing()
    mock_base_head()
    mock_runtime_root("substrate-stale-worktree")
    mock_checked_out_bump_branch()
    mock_worktree_commands("substrate-stale-worktree", true, old_branch_sha)
    mock_existing_pr()
    mock_bump_pr_view(nil, {
      rollup = '[{"name":"ci","status":"IN_PROGRESS","conclusion":""}]',
    })
    mock_bump_diff()
    mock_branch_present_at(pr_head_sha)
    mock_branch_pin_for_head(pr_head_sha, target_sha)
    mock_substrate_pin_ancestor(target_sha)

    local result = run_scan(opts("substrate-stale-worktree", { FKST_GITHUB_WRITE = "1" }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("git worktree remove --force /tmp/fkst-packages-test/github-devloop/stale-substrate"), 1)
    t.eq(count_calls("--force-with-lease=refs/heads/chore/substrate-ref-bump:" .. old_branch_sha), 1)
    eq_zero(count_calls("gh pr merge '27' --repo 'owner/repo' --merge --match-head-commit '" .. pr_head_sha .. "'"), "merge call after stale-worktree repin")
    eq_zero(count_raises(result, "github-proxy.github_issue_create_request"), "create raises after stale-worktree repin")
    eq_zero(count_raises(result, "github-proxy.github_issue_label_request"), "label raises after stale-worktree repin")
  end,
}
