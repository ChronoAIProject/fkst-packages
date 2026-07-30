local h = require("tests.devloop_helpers")
local t = h.t

return {
  test_implement_does_not_reclaim_noncanonical_worktree = function()
    local event = h.ready()
    local branch = h.deterministic_branch_for(event)
    h.mock_issue_implement({ "fkst-dev:ready" })
    h.mock_noncanonical_implement_worktree_conflict(
      "/tmp/fkst-packages-test/github-devloop/durable",
      branch
    )

    local result = h.run_implement(event, h.opts("implement-noncanonical-worktree-conflict"))
    t.eq(result.exit_code, 1)
    t.is_true(tostring(result.error):find("worktree-registration-conflict", 1, true) ~= nil)
    t.eq(h.count_calls("git worktree remove --force"), 0)
    t.eq(h.count_calls("git worktree add"), 0)
    t.eq(h.count_calls("codex exec"), 0)
  end,
}
