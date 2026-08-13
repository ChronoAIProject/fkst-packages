local t = fkst.test

local department = require("departments.observability.main")

local contains = require("testkit_internal.values").has_value

return {
  test_anomaly_queues_are_exactly_the_ephemeral_at_most_once_consumes = function()
    local issue_queue = "github-devloop.restart_transition_anomaly"
    local pr_queue = "github-devloop-pr.restart_transition_anomaly"
    t.eq(#department.spec.ephemeral, 2)
    t.eq(department.spec.ephemeral[1], pr_queue)
    t.eq(department.spec.ephemeral[2], issue_queue)
    t.is_true(contains(department.spec.consumes, issue_queue))
    t.is_true(contains(department.spec.consumes, pr_queue))
  end,

  test_anomaly_ingestion_handles_one_ephemeral_record_once = function()
    local captured = {}
    local previous_log = log
    log = {
      info = function(message) captured[#captured + 1] = tostring(message) end,
      warn = function(message) captured[#captured + 1] = tostring(message) end,
      error = function(message) captured[#captured + 1] = tostring(message) end,
    }
    local ok, failure = pcall(function()
      department.pipeline({
        queue = "github-devloop.restart_transition_anomaly",
        payload = {
          schema = "restart-transition-anomaly.v1",
          owner = "github-devloop",
          entity = { kind = "issue", repo = "owner/repo", number = 42 },
          decision_status = "indeterminate",
          reason_code = "cause-evidence-insufficient",
          cause_status = "indeterminate",
          ordering_status = "complete",
          evidence_refs = {},
          disposition = "cause-indeterminate",
        },
      })
    end)
    log = previous_log
    if not ok then
      error(failure)
    end

    local ingested = 0
    for _, line in ipairs(captured) do
      if line:find("tag=RESTART_TRANSITION_ANOMALY", 1, true) ~= nil then
        ingested = ingested + 1
      end
    end
    t.eq(ingested, 1)
  end,
}
