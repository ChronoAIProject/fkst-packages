local h = require("tests.proxy_integration_helpers")
local sha256 = require("contract.sha256")
local t = h.t

local function delivery_snapshot(deliveries, dead_letters, terminal_suppressions)
  return {
    schema_version = 1,
    generated_at_ms = 1785575100000,
    source = {
      durable_root = "/tmp/fkst-durable",
      database = "/tmp/fkst-durable/delivery.redb",
      read_semantics = "single read transaction",
      history_semantics = "mutable delivery queue snapshot",
    },
    limits = { max_deliveries = 10000, max_dead_letters = 10000, max_terminal_suppressions = 10000 },
    truncated = { deliveries = false, dead_letters = false, terminal_suppressions = false },
    queues = json.decode("[]"),
    deliveries = deliveries or json.decode("[]"),
    dead_letters = dead_letters or json.decode("[]"),
    terminal_suppressions = terminal_suppressions or json.decode("[]"),
  }
end

local function payload_summary(dedup_key)
  return {
    schema = "github-proxy.v1",
    dedup_key = dedup_key,
    digest = string.rep("c", 64),
    bytes = 128,
  }
end

local function source()
  return {
    kind = "cron",
    reference = "github-proxy.github_poll/slot/1785574800000",
  }
end

local function mock_poll_inputs(intake)
  h.mock_repo_env()
  h.mock_poll_label_prefix_env("fkst-class:")
  h.mock_proxy_replay_budget_env("1")
  h.mock_issue_list(h.poll_issue_list_from({ intake }))
  h.mock_pr_list("[]\n")
end

return {
  test_poll_rearms_from_a_populated_terminal_suppression_snapshot = function()
    local run_opts = h.opts("terminal-suppression-rearm", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "1",
    })
    local intake = '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"bug"}],"assignees":[]}'
    local queue = "github-proxy.github_entity_changed"
    local base_key = "owner/x#issue#50@2026-06-03T01:04:00Z"
    local suppression_id = "delivery/v3/raised/queue/github-proxy.github_entity_changed/dept/github-devloop-intake.admission/dedup/base"
    local expected_rearm_key = base_key .. "/rearm/" .. sha256.hex(suppression_id)
    local suppression = {
      delivery_id = suppression_id,
      queue = queue,
      dept = "github-devloop-intake.admission",
      terminal_at_ms = 1785575040000,
      dedup_key = base_key,
    }

    mock_poll_inputs(intake)
    t.mock_observe(delivery_snapshot(json.decode("[]"), json.decode("[]"), { suppression }))
    local result = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-terminal-suppression-rearm",
    }, run_opts)

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].payload.dedup_key, expected_rearm_key)
  end,

  test_poll_reuses_a_live_rearm_generation_before_requeueing_after_drain = function()
    local run_opts = h.opts("bounded-repeated-level-rearm", {
      FKST_GITHUB_PROXY_REPLAY_BUDGET = "1",
    })
    local intake = '{"number":50,"title":"Issue 50","html_url":"https://github.example/owner/x/issues/50","updated_at":"2026-06-03T01:04:00Z","state":"open","author":{"login":"fkst-test-bot"},"labels":[{"name":"bug"}],"assignees":[]}'
    local queue = "github-proxy.github_entity_changed"
    local base_key = "owner/x#issue#50@2026-06-03T01:04:00Z"
    local first_terminal_id = "delivery/v3/raised/queue/github-proxy.github_entity_changed/dept/github-devloop.observe_issue/dedup/base"
    local rearm_key = base_key .. "/rearm/" .. sha256.hex(first_terminal_id)
    local next_terminal_id = first_terminal_id .. "/rearm-1"
    local live_sibling = {
      delivery_id = "live-rearm-delivery",
      queue = queue,
      dept = "github-devloop-intake.admission",
      source = source(),
      status = "in-flight",
      observed_at_ms = 1785575040000,
      not_before_ms = 1785575040000,
      attempt = 0,
      redrive_count = 0,
      lease_generation = 1,
      lease_until_ms = 1785575070000,
      fence_token = "live-rearm-delivery#1",
      subscriber_absent_since_ms = nil,
      payload = payload_summary(rearm_key),
      last_error_excerpt = nil,
    }
    local newer_live_base = {
      delivery_id = "newer-live-base-delivery",
      queue = queue,
      dept = "github-devloop.observe_issue",
      source = source(),
      status = "in-flight",
      observed_at_ms = 1785575100000,
      not_before_ms = 1785575100000,
      attempt = 0,
      redrive_count = 0,
      lease_generation = 1,
      lease_until_ms = 1785575130000,
      fence_token = "newer-live-base-delivery#1",
      subscriber_absent_since_ms = nil,
      payload = payload_summary(base_key),
      last_error_excerpt = nil,
    }
    local repeated_terminal = {
      delivery_id = next_terminal_id,
      queue = queue,
      dept = "github-devloop.observe_issue",
      source = source(),
      observed_at_ms = 1785574980000,
      not_before_ms = 1785574980000,
      dead_at_ms = 1785575040000,
      attempts = 3,
      redrive_count = 3,
      replayable = false,
      permanent = true,
      payload = payload_summary(rearm_key),
      error_excerpt = "repeated transient observer failure",
    }

    mock_poll_inputs(intake)
    t.mock_observe(delivery_snapshot({ live_sibling, newer_live_base }, { repeated_terminal }))
    local bounded = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-rearm-live",
    }, run_opts)
    t.eq(bounded.exit_code, 0)
    t.eq(#bounded.raises, 1)
    t.eq(bounded.raises[1].payload.dedup_key, rearm_key)

    mock_poll_inputs(intake)
    t.mock_observe(delivery_snapshot({ newer_live_base }, { repeated_terminal }))
    local bounded_after_rearm_drains = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-rearm-z-drained",
    }, run_opts)
    t.eq(bounded_after_rearm_drains.exit_code, 0)
    t.eq(#bounded_after_rearm_drains.raises, 1)
    t.eq(bounded_after_rearm_drains.raises[1].payload.dedup_key, base_key)

    mock_poll_inputs(intake)
    t.mock_observe(delivery_snapshot(json.decode("[]"), { repeated_terminal }))
    local requeued = t.run_department("departments/github_poll/main.lua", {
      queue = "github_poll_tick",
      payload = {},
      ts = "poll-rearm-zz-all-drained",
    }, run_opts)
    t.eq(requeued.exit_code, 0)
    t.eq(#requeued.raises, 1)
    t.eq(
      requeued.raises[1].payload.dedup_key,
      base_key .. "/rearm/" .. sha256.hex(next_terminal_id)
    )
  end,
}
