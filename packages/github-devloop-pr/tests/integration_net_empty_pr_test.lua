local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local m_builders = require("devloop.markers.builders")

local reviewing = h.reviewing
local review_reached = h.review_reached
local run_review_result = h.run_review_result
local run_review_pr = h.run_review_pr
local run_fix = h.run_fix
local mock_pr_origin = h.mock_pr_origin
local mock_issue_result = h.mock_issue_result
local mock_issue_review = h.mock_issue_review
local mock_issue_fix_for_event = h.mock_issue_fix_for_event
local mock_pr_fix = h.mock_pr_fix
local mock_existing_fix_worktree = h.mock_existing_fix_worktree
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local mock_git_push = h.mock_git_push
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local count_calls = h.count_calls
local find_raise = h.find_raise
local find_causal_raise = h.find_causal_raise

local proposal_id = "github-devloop/issue/owner/repo/42"
local branch = "devloop-owner-repo-42-01HY"
local net_empty_head = "ace02413"

local function origin_marker(version)
  return m_builders.pr_origin_marker(proposal_id, "42", branch, version, "dev")
end

local function raise_summary(raises)
  local parts = {}
  for _, raised in ipairs(raises or {}) do
    table.insert(parts, tostring(raised.queue))
  end
  return table.concat(parts, ",")
end

local function result_summary(result)
  return "raises=" .. raise_summary(result and result.raises)
    .. " stdout=" .. tostring(result and result.stdout)
    .. " stderr=" .. tostring(result and result.stderr)
    .. " error=" .. tostring(result and result.error)
end

local function mock_write_env_many(value, times)
  for _ = 1, times do
    mock_write_env(value)
  end
end

return {
  test_net_empty_pr_after_fix_marks_closed_unmerged_without_review_proposal = function()
    local event = reviewing()
    local impl_version = event.version
    local review = review_reached({
      decision = "reject",
      body = "Review consensus rejects the closeout-only artifact.",
      blocking_gap = "closeout artifact is not legitimate implementation progress",
      angle_results = {
        { angle = "minimal", verdict = "reject" },
        { angle = "structural", verdict = "reject" },
        { angle = "delete", verdict = "reject" },
      },
    })
    mock_pr_origin({ origin_marker(impl_version) }, branch, "def456", "OPEN", "dev")
    mock_issue_result({ "fkst-dev:reviewing" }, {
      core.state_marker(proposal_id, "reviewing", impl_version),
    })

    local rejected = run_review_result(review, opts("empty-pr-churn-review-reject"))
    t.eq(rejected.exit_code, 0)
    local reject_comment = find_raise(rejected.raises, "github-proxy.github_pr_comment_request")
    local fixing_raise = find_causal_raise(rejected, "devloop_fixing")
    if reject_comment == nil then
      error("review reject did not raise PR comment, got: " .. raise_summary(rejected.raises))
    end
    if fixing_raise == nil then
      error("review reject did not raise fixing, got: " .. raise_summary(rejected.raises))
    end
    t.eq(fixing_raise.payload.reviewed_head_sha, "def456")

    local fixing_comments = {
      origin_marker(impl_version),
      core.state_marker(proposal_id, "fixing", fixing_raise.payload.version),
      reject_comment.payload.body,
    }
    mock_bot_env()
    mock_write_env("1")
    mock_issue_fix_for_event(fixing_raise.payload, { "fkst-dev:fixing" }, fixing_comments, branch, impl_version)
    mock_pr_fix(fixing_comments, branch, "def456")
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
      stderr = "",
      exit_code = 0,
    })
    mock_existing_fix_worktree(branch, "def456")
    mock_implement_codex(0, "removed closeout artifact")
    mock_git_status(" D CLOSEOUT.md\n")
    mock_git_commit(net_empty_head, branch)
    mock_write_env("1")
    mock_issue_fix_for_event(fixing_raise.payload, { "fkst-dev:fixing" }, fixing_comments, branch, impl_version)
    mock_git_push(branch)
    mock_pr_fix(fixing_comments, branch, net_empty_head)

    local fixed = run_fix(fixing_raise.payload, opts("empty-pr-churn-fix-strip", {
      FKST_GITHUB_WRITE = "1",
    }))
    t.eq(fixed.exit_code, 0)
    local fix_comment = find_raise(fixed.raises, "github-proxy.github_pr_comment_request")
    local reviewing_raise = find_causal_raise(fixed, "devloop_reviewing")
    if fix_comment == nil then
      error("fix strip did not raise PR comment, got: " .. result_summary(fixed))
    end
    if reviewing_raise == nil then
      error("fix strip did not raise reviewing, got: " .. raise_summary(fixed.raises))
    end
    t.eq(reviewing_raise.payload.schema, "github-devloop.reviewing.v1")
    reviewing_raise.payload.head_sha = net_empty_head
    reviewing_raise.payload._test_empty_diff_name_only = true

    mock_bot_env()
    mock_issue_review({ "fkst-dev:reviewing" }, {
      fix_comment.payload.body,
    })
    mock_pr_origin({ origin_marker(impl_version) }, branch, net_empty_head, "OPEN", "dev")
    mock_write_env_many("1", 4)
    t.mock_command("gh pr close '7' --repo 'owner/repo'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    local re_review = run_review_pr(reviewing_raise.payload, opts("empty-pr-churn-net-empty-review", {
      FKST_TEST_PR_EMPTY_DIFF_NAME_ONLY = "1",
      FKST_GITHUB_WRITE = "1",
    }))
    if re_review.exit_code ~= 0 then
      error("net-empty review step failed: " .. result_summary(re_review))
    end
    local unexpected_proposal = find_raise(re_review.raises, "devloop_review_request")
    if unexpected_proposal ~= nil then
      error("net-empty review raised proposal; name_only_calls="
        .. tostring(count_calls("gh pr diff '7' --repo 'owner/repo' --name-only"))
        .. " high_risk=" .. tostring(unexpected_proposal.payload.high_risk)
        .. " raises=" .. raise_summary(re_review.raises))
    end
    local terminal = find_raise(re_review.raises, "github-proxy.github_pr_comment_request")
    if terminal == nil then
      error("expected closed-unmerged PR comment raise, got: " .. raise_summary(re_review.raises))
    end
    if terminal.payload.body:find("no-legitimate-diff", 1, true) == nil then
      error("closed-unmerged comment lacks no-legitimate-diff reason: " .. tostring(terminal.payload.body))
    end
    if terminal.payload.body:find('state="closed-unmerged"', 1, true) == nil then
      error("closed-unmerged comment lacks state marker: " .. tostring(terminal.payload.body))
    end
    t.eq(terminal.payload.handoff.kind, "github-devloop.closed_unmerged")
    t.is_true(count_calls("gh pr diff '7' --repo 'owner/repo' --name-only") > 0)
    t.eq(count_calls("gh pr close '7' --repo 'owner/repo'"), 1)
  end,
}
