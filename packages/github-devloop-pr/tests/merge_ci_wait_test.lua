local ci_wait = require("core.merge_ci_wait")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local t = h.t

return {
  test_hold_returns_same_tagged_outcome_for_each_ci_wait_class = function()
    local merge_ready = {
      proposal_id = "github-devloop/issue/owner/repo/42",
      pr_number = 7,
      version = "ready/github-devloop/issue/owner/repo/42/intake/1",
      reviewed_head_sha = "def456",
    }
    local cases = {
      { kind = "CHECKS_PENDING", reason = "checks-pending" },
      { kind = "CI_UNKNOWN", reason = "ci-unknown" },
      { kind = "INTEGRATION_RED", reason = "integration-ci-red" },
      { kind = "EXTERNAL_CI_RED", reason = "external-ci-red" },
    }

    for _, case in ipairs(cases) do
      local result = testing.run_fake({
        pipeline = function()
          return ci_wait.hold(nil, merge_ready, "owner/repo", { head_sha = "def456" }, case)
        end,
      }, { payload = {} })

      t.eq(result.failure, nil, case.kind .. " exits cleanly")
      t.eq(result.result.status, "hold", case.kind .. " returns the hold tag")
      t.eq(result.result.reason, case.reason, case.kind .. " preserves the reason")
      t.eq(#result.raises, 1, case.kind .. " emits one durable wait fact")
      t.eq(result.raises[1].queue, "github-proxy.github_pr_comment_request")
      t.is_true(result.raises[1].payload.body:find("fkst:github-devloop:merge-gate-wait:v1", 1, true) ~= nil)
      t.is_true(result.raises[1].payload.body:find('kind="' .. case.kind .. '"', 1, true) ~= nil)
      t.is_true(result.raises[1].payload.body:find('reason="' .. case.reason .. '"', 1, true) ~= nil)
    end
  end,
}
