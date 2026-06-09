local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

local function find_raise(raises, queue)
  for _, raised in ipairs(raises or {}) do
    if raised.queue == queue then
      return raised
    end
  end
  return nil
end

local function mock_env()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_status_card_tick_raises_upsert_for_active_issue = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/review-loop/2"
    local state_marker = core.state_marker(proposal_id, "reviewing", version)
    local action_comment = {
      body = "github-devloop PR review convergence round 2\n\nReview is still narrowing.",
      author_login = "fkst-test-bot",
      created_at = "2026-06-03T02:00:00Z",
    }

    mock_env()
    h.mock_issue_status_card_list({ "fkst-dev:reviewing" })
    h.mock_issue_status_card({ "fkst-dev:reviewing" }, "OPEN", {
      state_marker,
      action_comment,
    })

    local result = h.run_status_card(h.opts("status-card-active", {
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)

    local raised = find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.eq(raised.payload.upsert, true)
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.issue_number, "42")
    t.eq(raised.payload.dedup_key, "status-card/comment/github-devloop/issue/owner/repo/42")
    t.eq(raised.payload.source_ref.ref, "owner/repo#issue/42")
    t.eq(raised.payload.body, nil)
    t.eq(raised.payload.render.kind, "github-devloop-status-card")
    t.eq(raised.payload.render.proposal_id, proposal_id)
  end,

  test_status_card_tick_skips_terminal_issue = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    h.mock_issue_status_card_list({ "fkst-dev:blocked" })
    h.mock_issue_status_card({ "fkst-dev:blocked" }, "OPEN", {
      core.state_marker(proposal_id, "blocked", "v1"),
    })

    local result = h.run_status_card(h.opts("status-card-terminal", {
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
  end,
}
