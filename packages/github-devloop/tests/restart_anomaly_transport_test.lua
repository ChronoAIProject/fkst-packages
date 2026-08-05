local h = require("tests.devloop_helpers")

local t = h.t
local core = h.core
local proposal_id = "github-devloop/issue/owner/repo/42"

local function marker(state, version, created_at)
  return {
    body = h.state_comment(proposal_id, state, version),
    author_login = "fkst-test-bot",
    created_at = created_at,
  }
end

local function anomaly_records(raises)
  local records = {}
  for _, item in ipairs(raises or {}) do
    if item.queue == "restart_transition_anomaly" then
      records[#records + 1] = item.payload
    end
  end
  return records
end

local function assert_grantless_ephemeral_record(record)
  t.eq(record.schema, "restart-transition-anomaly.v1")
  t.eq(record.owner, "github-devloop")
  t.eq(record.entity.kind, "issue")
  t.eq(record.entity.repo, "owner/repo")
  t.eq(record.entity.number, 42)
  for _, field in ipairs({
    "source_ref", "dedup_key", "delivery_id", "delivery_key",
    "durable_identity", "event_id", "idempotency_key", "message_id", "grant",
  }) do
    t.eq(record[field], nil, "anomaly transport must omit " .. field)
  end
end

local function run_pass(updated_at)
  local comments = {
    marker("thinking", "2026-07-24T01-00-00Z", "2026-07-24T01:00:00Z"),
    marker("ready", "2026-07-24T01-01-00Z", "2026-07-24T01:01:00Z"),
    marker("ready", "2026-07-24T01-02-00Z", "2026-07-24T01:02:00Z"),
  }
  h.mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready" }, "OPEN", comments)
  return h.run_observe(h.issue({ updated_at = updated_at }), h.opts("restart-anomaly-transport"))
end

return {
  test_issue_owner_emits_fresh_independent_anomalies_each_pass = function()
    local department = require("departments.observe_issue.main")
    t.eq(department.spec.produces[#department.spec.produces], "restart_transition_anomaly")

    local first = run_pass("2026-07-24T01:03:00Z")
    t.eq(first.exit_code, 0)
    local first_records = anomaly_records(first.raises)
    t.eq(#first_records, 2)
    assert_grantless_ephemeral_record(first_records[1])
    assert_grantless_ephemeral_record(first_records[2])

    local second = run_pass("2026-07-24T01:04:00Z")
    t.eq(second.exit_code, 0)
    local second_records = anomaly_records(second.raises)
    t.eq(#second_records, 2)
    assert_grantless_ephemeral_record(second_records[1])
    assert_grantless_ephemeral_record(second_records[2])
  end,
}
