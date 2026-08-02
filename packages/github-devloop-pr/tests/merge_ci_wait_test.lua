local ci_wait = require("core.merge_ci_wait")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local t = h.t

return {
  test_hold_returns_tagged_outcome_after_emitting_wait_fact = function()
    local merge_ready = {
      proposal_id = "github-devloop/issue/owner/repo/42",
      pr_number = 7,
      version = "ready/github-devloop/issue/owner/repo/42/intake/1",
      reviewed_head_sha = "def456",
    }
    local result = testing.run_fake({
      pipeline = function()
        return ci_wait.hold(nil, merge_ready, "owner/repo", { head_sha = "def456" }, {
          kind = "CI_UNKNOWN",
          reason = "ci-unknown",
        })
      end,
    }, { payload = {} })

    t.eq(result.failure, nil)
    t.eq(result.result.status, "hold")
    t.eq(result.result.reason, "ci-unknown")
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github-proxy.github_pr_comment_request")
    t.is_true(result.raises[1].payload.body:find("fkst:github-devloop:merge-gate-wait:v1", 1, true) ~= nil)
    t.is_true(result.raises[1].payload.body:find('kind="CI_UNKNOWN"', 1, true) ~= nil)
    t.is_true(result.raises[1].payload.body:find('reason="ci-unknown"', 1, true) ~= nil)
  end,
}
