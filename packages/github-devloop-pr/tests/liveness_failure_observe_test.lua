local testing = require("testkit_internal.testing")

local department = require("departments.observe_pr.main")
local t = fkst.test

return {
  test_liveness_failure_observation_fails_before_normal_pr_reconciliation = function()
    local result = testing.run_fake_expecting_failure(department, {
      queue = "github-devloop-pr.devloop_observe_pr",
      payload = {
        schema = "github-proxy.v1",
        type = "pr",
        repo = "owner/repo",
        number = 7,
        updated_at = "2026-06-03T01:02:03Z",
        dedup_key = "liveness-scan-failure/github-devloop/pr/owner/repo/7/lineage/timeout-redrive-stuck/fp-1",
        proposal_id = "github-devloop/pr/owner/repo/7",
        source = "liveness-scan",
        source_ref = { kind = "external", ref = "owner/repo#pr/7" },
        failure = {
          error_class = "timeout-redrive-stuck",
          fingerprint = "fp-1",
        },
      },
    })

    t.is_true(tostring(result.failure.error):find(
      "github-devloop: liveness-scan-entity-failure:",
      1,
      true
    ) ~= nil)
    t.is_true(tostring(result.failure.error):find(
      "cause_error_class=timeout-redrive-stuck",
      1,
      true
    ) ~= nil)
  end,
}
