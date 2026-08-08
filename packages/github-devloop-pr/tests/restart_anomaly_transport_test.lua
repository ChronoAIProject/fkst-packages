local h = require("tests.devloop_helpers")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")

local t = h.t
local core = h.core
local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local branch = "devloop-owner-repo-42-01HY"

local function pr_event()
  return {
    schema = "github-proxy.v1",
    type = "pr",
    repo = repo,
    number = 7,
    state = "OPEN",
    updated_at = "2026-06-04T01:02:03Z",
    labels = {},
    dedup_key = "owner/repo#pr#7@2026-06-04T01:02:03Z",
    source_ref = h.pr_source_ref(),
  }
end

local function mock_self_owned_issue()
  t.mock_command(core.gh_issue_view_claim_cmd(repo, 42), {
    stdout = '{"labels":[{"name":"fkst-dev:claimed:fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(core.gh_issue_view_result_cmd(repo, 42), {
    stdout = '{"labels":[{"name":"fkst-dev:fixing"}],"comments":[]}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_pr()
  local comments = {
    m_builders.pr_origin_marker(proposal_id, "42", branch, version, "dev"),
    core.state_marker(proposal_id, "pr-open", version),
    core.state_marker(proposal_id, "reviewing", version),
  }
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = repo,
    number = 7,
    comments = comments,
    head = branch,
    head_sha = "def456",
    base_branch = "dev",
    state = "OPEN",
    mergeable = "MERGEABLE",
    merge_state = "CLEAN",
  }, entity_read_mocks.pr_origin_selector)
end

local function run_pass(pass)
  h.mock_bot_env()
  mock_self_owned_issue()
  mock_pr()
  return t.run_department("departments/observe_pr/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = pr_event(),
  }, h.opts("restart-anomaly-transport-pass-" .. tostring(pass)))
end

local function assert_grantless_ephemeral_record(record)
  t.eq(record.schema, "restart-transition-anomaly.v1")
  t.eq(record.owner, "github-devloop-pr")
  t.eq(record.entity.kind, "pr")
  t.eq(record.entity.repo, repo)
  t.eq(record.entity.number, 7)
  for _, field in ipairs({
    "source_ref", "dedup_key", "delivery_id", "delivery_key",
    "durable_identity", "event_id", "idempotency_key", "message_id", "grant",
  }) do
    t.eq(record[field], nil, "anomaly transport must omit " .. field)
  end
end

return {
  test_pr_owner_emits_fresh_grantless_anomaly_each_pass = function()
    local department = require("departments.observe_pr.main")
    t.eq(department.spec.produces[#department.spec.produces], "restart_transition_anomaly")

    for pass = 1, 2 do
      local result = run_pass(pass)
      t.eq(result.exit_code, 0)
      local anomaly = h.find_raise(result.raises, "restart_transition_anomaly")
      t.is_true(anomaly ~= nil)
      assert_grantless_ephemeral_record(anomaly.payload)
    end
  end,
}
