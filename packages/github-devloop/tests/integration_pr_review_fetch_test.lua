local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local reviewing = h.reviewing
local run_review_pr = h.run_review_pr
local mock_issue_review = h.mock_issue_review
local mock_pr_origin = h.mock_pr_origin
local mock_pr_origin_sequence = h.mock_pr_origin_sequence
local mock_pr_diff = h.mock_pr_diff
local count_calls = h.count_calls

return {
  test_review_pr_retries_when_pr_diff_fetch_fails = function()
    local event = reviewing()
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker(event.proposal_id, "reviewing", event.version),
    })
    mock_pr_origin_sequence({
      { head = "devloop-owner-repo-42-01HY", head_sha = "def456" },
      { head = "devloop-owner-repo-42-01HY", head_sha = "def456" },
    })
    mock_pr_diff("", 1, "network unavailable")

    local result = run_review_pr(event, opts("review-pr-diff-fetch-fails"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 1)
    t.eq(count_calls("git worktree add"), 0)
    t.eq(count_calls("--json headRefName,headRefOid,baseRefName,state,comments"), 2)
  end,

  test_review_pr_retries_when_head_moves_after_pr_diff_fetch = function()
    local event = reviewing()
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker(event.proposal_id, "reviewing", event.version),
    })
    mock_pr_origin_sequence({
      { head = "devloop-owner-repo-42-01HY", head_sha = "def456" },
      { head = "devloop-owner-repo-42-01HY", head_sha = "def456" },
    })
    mock_pr_diff("diff --git a/file.lua b/file.lua\n+return true\n")
    mock_pr_origin({}, "devloop-owner-repo-42-01HY", "feedface")

    local result = run_review_pr(event, opts("review-pr-head-moved-after-diff"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 1)
    t.eq(count_calls("git worktree add"), 0)
    t.eq(count_calls("--json headRefName,headRefOid,baseRefName,state,comments"), 3)
  end,

  test_review_pr_fetch_probe_does_not_embed_diff_payload = function()
    local event = reviewing()
    local diff_sentinel = "DIFF_SENTINEL_MUST_NOT_ENTER_PROPOSAL"
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker(event.proposal_id, "reviewing", event.version),
    }, {
      title = "Implement decision recorder",
      body = "ISSUE_BODY_SENTINEL_MUST_NOT_ENTER_PROPOSAL",
    })
    mock_pr_origin_sequence({
      { head = "devloop-owner-repo-42-01HY", head_sha = "def456" },
      { head = "devloop-owner-repo-42-01HY", head_sha = "def456" },
    })
    h.mock_review_worktree("devloop-owner-repo-42-01HY", "def456", nil, "diff --git a/file.lua b/file.lua\n+" .. diff_sentinel .. "\n")

    local result = run_review_pr(event, opts("review-pr-diff-probe-only"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local proposal = result.raises[1].payload
    t.eq(proposal.source_ref.kind, "external")
    t.eq(proposal.source_ref.ref, "owner/repo#pr/7")
    h.assert_pr_review_fetch_sources(proposal, "owner/repo", "42", 7, "def456")
    t.is_true(tostring(proposal.codex_cwd or ""):find("/worktrees/devloop-owner-repo-42-", 1, true) ~= nil)
    t.eq(core.validate_proposal(proposal), true)
    t.eq(count_calls("gh pr diff"), 1)
    t.eq(count_calls("--json headRefName,headRefOid,baseRefName,state,comments"), 3)
  end,
}
