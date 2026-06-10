local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local reviewing = h.reviewing
local review_reached = h.review_reached
local merge_ready = h.merge_ready
local run_review_result = h.run_review_result
local run_merge = h.run_merge
local mock_issue_result = h.mock_issue_result
local mock_issue_merge = h.mock_issue_merge
local merge_comments = h.merge_comments
local mock_pr_origin = h.mock_pr_origin
local mock_pr_merge = h.mock_pr_merge
local mock_merging_comment = h.mock_merging_comment
local mock_pr_merge_command = h.mock_pr_merge_command
local mock_pr_ready = h.mock_pr_ready
local mock_issue_close = h.mock_issue_close
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local count_calls = h.count_calls

return {
  test_review_result_approve_does_not_convert_pr_ready_before_merge_gate = function()
    local event = review_reached()
    local impl_version = reviewing().version
    mock_pr_origin({
      core.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", impl_version, "dev"),
    })
    mock_bot_env()
    mock_write_env("1")
    mock_issue_result({ "fkst-dev:reviewing" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", impl_version),
    })
    local ready_calls_before = count_calls("gh pr ready")

    local result = run_review_result(event, opts("review-result-ready-no-early-ready", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr ready"), ready_calls_before)
    t.is_true(h.find_raise(result.raises, "devloop_merge_ready") ~= nil)
  end,

  test_review_result_approve_dry_run_does_not_convert_pr_ready = function()
    local event = review_reached()
    local impl_version = reviewing().version
    mock_pr_origin({
      core.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", impl_version, "dev"),
    })
    mock_issue_result({ "fkst-dev:reviewing" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", impl_version),
    })

    local result = run_review_result(event, opts("review-result-ready-dry-run"))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr ready"), 0)
  end,

  test_merge_converts_still_draft_pr_before_merging = function()
    local event = merge_ready()
    local origin_marker = core.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_pr_merge({ origin_marker }, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, true)
    mock_pr_ready()
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(event))
    mock_write_env("1")
    mock_pr_merge({ origin_marker }, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, true)
    mock_merging_comment()
    mock_pr_merge_command()
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "def456", "MERGED", "owner/repo", false, "MERGEABLE", "CLEAN", "COMPLETED", "SUCCESS", "2026-06-03T02:03:04Z")
    mock_issue_close()

    local result = run_merge(event, opts("merge-ready-draft-pr", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr ready '7' --repo 'owner/repo'"), 1)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(count_calls("gh issue close"), 1)
  end,
}
