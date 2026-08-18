local testing = require("testkit_internal.testing")

local department = require("departments.observe_pr.main")
local t = fkst.test

local function failure_event(error_class, message)
  return {
    queue = "github-devloop-pr.devloop_observe_pr",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = "owner/repo",
      number = 7,
      updated_at = "2026-06-03T01:02:03Z",
      dedup_key = "liveness-scan-failure/github-devloop/pr/owner/repo/7/lineage/" .. error_class .. "/fp-1",
      proposal_id = "github-devloop/pr/owner/repo/7",
      source = "liveness-scan",
      source_ref = { kind = "external", ref = "owner/repo#pr/7" },
      failure = {
        error_class = error_class,
        fingerprint = "fp-1",
        message = message,
      },
    },
  }
end

return {
  test_liveness_failure_observation_fails_before_normal_pr_reconciliation = function()
    local cause = "replay did not emit a consumable redrive; outcome=missing-required-fact"
    local result = testing.run_fake_expecting_failure(
      department,
      failure_event("timeout-redrive-stuck", cause)
    )

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
    t.is_true(tostring(result.failure.error):find(cause, 1, true) ~= nil)
  end,

  test_liveness_failure_observation_preserves_untyped_cause = function()
    local cause = "distinctive upstream failure without a semantic envelope"
    local result = testing.run_fake_expecting_failure(
      department,
      failure_event("caught-failure", cause)
    )

    t.is_true(tostring(result.failure.error):find("cause_error_class=caught-failure", 1, true) ~= nil)
    t.is_true(tostring(result.failure.error):find(cause, 1, true) ~= nil)
  end,
}
