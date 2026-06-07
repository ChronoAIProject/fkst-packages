local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local reviewing = h.reviewing
local review_unresolved = h.review_unresolved
local run_review_scan = h.run_review_scan
local mock_issue_review = h.mock_issue_review
local mock_pr_origin = h.mock_pr_origin
local mock_pr_list_open = h.mock_pr_list_open
local mock_pr_diff = h.mock_pr_diff
local find_raise = h.find_raise
local count_calls = h.count_calls

local function mock_env()
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_UPSTREAM_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_INTEGRATION_BRANCH"', { stdout = "dev", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_MERGE"', { stdout = "auto", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
end

return {
  test_review_scan_replays_lost_review_loop_continuation = function()
    local event = reviewing()
    local review_id = core.pr_review_proposal_id("owner/repo", event.pr_number, event.version, "def456")
    local unresolved = review_unresolved({
      proposal_id = review_id,
      dedup_key = "consensus:" .. review_id .. "/review",
    })

    mock_env()
    mock_pr_list_open({
      {
        number = event.pr_number,
        head = "devloop-owner-repo-42-01HY",
        head_sha = "def456",
        base = "dev",
      },
    })
    mock_pr_origin({
      core.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev"),
    })
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker(event.proposal_id, "reviewing", event.version),
      core.review_loop_marker(review_id, event.proposal_id, 1, unresolved.dedup_key),
    }, {
      title = "Implement decision recorder",
      body = "Issue context",
    })
    mock_pr_diff("diff --git a/core.lua b/core.lua\n+return true\n")
    mock_pr_origin({
      core.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev"),
    })

    local result = run_review_scan(opts("review-scan-replay-loop"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local proposal = find_raise(result.raises, "consensus.proposal").payload
    t.eq(proposal.proposal_id, review_id)
    t.eq(proposal.dedup_key, review_id .. "/review/loop/1")
    t.is_true(proposal.body:find("+return true", 1, true) ~= nil)
    t.eq(count_calls("gh pr list"), 1)
    t.eq(count_calls("gh pr diff"), 1)
  end,

  test_review_scan_replays_missing_initial_review_event = function()
    local event = reviewing()

    mock_env()
    mock_pr_list_open({
      {
        number = event.pr_number,
        head = "devloop-owner-repo-42-01HY",
        head_sha = "def456",
        base = "dev",
      },
    })
    mock_pr_origin({
      core.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev"),
    })
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker(event.proposal_id, "reviewing", event.version),
    })
    local result = run_review_scan(opts("review-scan-replay-initial"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local payload = find_raise(result.raises, "devloop_reviewing").payload
    t.eq(payload.schema, "github-devloop.reviewing.v1")
    t.eq(payload.proposal_id, event.proposal_id)
    t.eq(payload.pr_number, event.pr_number)
    t.eq(payload.version, event.version)
    t.eq(count_calls("gh pr diff"), 0)
  end,

  test_review_scan_does_not_replay_exhausted_review_loop = function()
    local event = reviewing()
    local review_id = core.pr_review_proposal_id("owner/repo", event.pr_number, event.version, "def456")
    local exhausted_dedup = "consensus:" .. review_id .. "/review/loop/2"

    mock_env()
    mock_pr_list_open({
      {
        number = event.pr_number,
        head = "devloop-owner-repo-42-01HY",
        head_sha = "def456",
        base = "dev",
      },
    })
    mock_pr_origin({
      core.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", event.version, "dev"),
    })
    mock_issue_review({ "fkst-dev:reviewing" }, {
      core.state_marker(event.proposal_id, "reviewing", event.version),
      core.review_loop_marker(review_id, event.proposal_id, core.loop_budget(), exhausted_dedup),
    })
    local result = run_review_scan(opts("review-scan-exhausted-loop"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh pr diff"), 0)
  end,
}
