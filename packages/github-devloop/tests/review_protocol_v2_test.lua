local h = require("tests.devloop_helpers")
local core = h.core
local t = h.t

local function review_event(extra)
  return h.review_reached(extra)
end

return {
  test_review_result_approve_with_advisory_still_authorizes_merge_ready = function()
    local event = review_event({
      proposal_id = core.pr_review_proposal_id("owner/repo", 7, h.reviewing().version, "def456"),
      body = "minimal:\nLooks good.\n\nAdvisory (non-blocking):\nstructural:\nRename helper later.",
      angle_results = {
        { angle = "minimal", verdict = "approve" },
        { angle = "structural", verdict = "comment" },
      },
    })
    local impl_version = h.reviewing().version
    h.mock_pr_origin({
      core.pr_origin_marker("github-devloop/issue/owner/repo/42", "42", "devloop-owner-repo-42-01HY", impl_version, "dev"),
    })
    h.mock_issue_result({ "fkst-dev:reviewing" }, {
      core.state_marker("github-devloop/issue/owner/repo/42", "reviewing", impl_version),
    })

    local result = h.run_review_result(event, h.opts("review-v2-approve-advisory"))
    t.eq(result.exit_code, 0)
    t.is_true(h.find_raise(result.raises, "devloop_merge_ready") ~= nil)
    local comment = h.find_raise(result.raises, "github-proxy.github_pr_comment_request").payload.body
    t.is_true(comment:find("github-devloop PR review decision: approve", 1, true) ~= nil)
    t.is_true(comment:find("Advisory (non-blocking):", 1, true) ~= nil)
  end,

  test_reject_without_blocking_gap_fails_closed_before_fixing = function()
    local event = review_event({
      decision = "reject",
    })
    event.blocking_gap = nil
    local impl_version = h.reviewing().version
    h.mock_pr_origin({
      core.pr_origin_marker(event.proposal_id, "42", "devloop-owner-repo-42-01HY", impl_version, "dev"),
    })

    local result = h.run_review_result(event, h.opts("review-v2-reject-missing-gap"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_fix_prompt_uses_named_gap_and_ledger_feeds_post_fix_review = function()
    local fix = h.fixing({ blocking_gap = "missing rollback guard" })
    local prompt = core.build_fix_prompt(fix, { title = "Issue title" }, "Reject prose with advisory.", "Approved framing.")
    t.is_true(prompt:find("Apply the SMALLEST change that closes the named blocking gap: missing rollback guard", 1, true) ~= nil)
    t.is_true(prompt:find("Do not address advisory comments.", 1, true) ~= nil)
    t.is_true(prompt:find("State in your summary which gap you closed.", 1, true) ~= nil)

    local reject_comment = core.build_review_result_comment_request(
      "owner/repo",
      "42",
      fix.proposal_id,
      fix.version,
      {
        proposal_id = fix.review_proposal_id,
        decision = "reject",
        body = "Reject body.",
        blocking_gap = "missing rollback guard",
        dedup_key = fix.review_dedup_key,
        source_ref = fix.source_ref,
      },
      fix.source_ref
    ).body
    local fix_comment = core.build_fix_reviewing_comment_request(
      "owner/repo",
      "42",
      {
        proposal_id = fix.proposal_id,
        pr_number = fix.pr_number,
        review_proposal_id = fix.review_proposal_id,
        review_dedup_key = fix.review_dedup_key,
        source_ref = fix.source_ref,
        fix_summary = "Closed gap: missing rollback guard.",
      },
      "def456",
      "feedface",
      core.next_fix_version(fix.version)
    ).body
    local proposal = core.build_pr_review_proposal(
      "owner/repo",
      "42",
      7,
      core.next_fix_version(fix.version),
      "feedface",
      {
        title = "Issue title",
        comments = {
          { body = reject_comment, author_login = "fkst-test-bot" },
          { body = fix_comment, author_login = "fkst-test-bot" },
        },
      },
      fix.source_ref
    )
    t.is_true(proposal.body:find("Prior review ledger:", 1, true) ~= nil)
    t.is_true(proposal.body:find("Last named blocking gap: missing rollback guard", 1, true) ~= nil)
    t.is_true(proposal.body:find("Latest fix-round summary: Closed gap: missing rollback guard.", 1, true) ~= nil)
    t.is_true(proposal.body:find("Judge whether THE NAMED GAP is closed", 1, true) ~= nil)
  end,
}
