local t = fkst.test
local runtime_health = require("core.rollup_health")
local generated_at_ms = 1781832600000

local function verdict(snapshot)
  if type(snapshot) == "table" then
    snapshot.generated_at_ms = snapshot.generated_at_ms or generated_at_ms
    snapshot.truncated = snapshot.truncated or { deliveries = false, dead_letters = false }
    snapshot.dead_letters = snapshot.dead_letters or {}
  end
  return runtime_health.verdict(snapshot, {
    now_seconds = 1781832600,
    stall_seconds = 1800,
    failure_window_seconds = 1800,
  })
end

local function assert_clean(snapshot)
  local result = verdict(snapshot)
  t.eq(result.clean, true)
  t.eq(result.reason, "clean")
end

local function assert_dirty(snapshot, reason)
  local result = verdict(snapshot)
  t.eq(result.clean, false)
  t.eq(result.reason, reason)
end

-- Promotion-health fixtures are windowed to the candidate soak interval.
-- scripts/board.py intentionally retains cumulative operator-attention semantics.
return {
  test_observe_runtime_health_uses_configured_soak_window = function()
    t.mock_observe({
      schema_version = 1,
      generated_at_ms = generated_at_ms,
      truncated = { deliveries = false, dead_letters = false },
      dead_letters = json.decode("[]"),
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_ROLLUP_RUNTIME_SOAK_MINUTES"', {
      stdout = "30",
      stderr = "",
      exit_code = 0,
    })
    local result = runtime_health.observe_runtime_health()
    t.eq(result.reason, "clean")
    t.eq(result.clean, true)
  end,

  test_runtime_health_clean_snapshot_is_clean = function()
    assert_clean({
      schema_version = 1,
      generated_at_ms = 1781832600000,
      queues = {
        { queue = "devloop_ready", depth = 1, pending = 1, in_flight = 0, retrying = 0 },
      },
      deliveries = {
        { delivery_id = "delivery-1", queue = "devloop_ready", status = "pending" },
      },
      dead_letters = {},
    })
  end,

  test_runtime_health_retry_pending_transient_is_clean = function()
    assert_clean({
      entities = {
        {
          entity = "github-devloop/issue/owner/repo/623",
          events = {
            {
              queue = "devloop_ready",
              outcome = "retry-pending",
              error_class = "retry-pending",
              ts = "2026-06-14T09:59:30Z",
            },
          },
        },
      },
      queues = {
        { queue = "devloop_ready", ready = 0, leased = 0, retry = 1, dlq = 0 },
      },
      failure_facts = {
        {
          origin_queue = "devloop_ready",
          origin_dept = "github-devloop.implement",
          error_class = "retry-pending",
          fingerprint = "retry-pending:abc",
          attempt = 1,
        },
      },
    })
  end,

  test_runtime_health_expected_transients_are_clean = function()
    assert_clean({
      entities = {
        {
          entity = "github-devloop/issue/owner/repo/623",
          events = {
            {
              queue = "devloop_observe_tick",
              outcome = "deadline-defer",
              ts = "2026-06-14T09:00:00Z",
            },
            {
              queue = "devloop_merge_ready",
              error_class = "marker-lag",
              ts = "2026-06-14T09:00:00Z",
            },
            {
              queue = "github-proxy.github_entity_changed",
              outcome = "skip-foreign",
              ts = "2026-06-14T09:00:00Z",
            },
          },
        },
      },
    })
  end,

  test_runtime_health_recent_dead_letter_snapshot_is_dirty = function()
    assert_dirty({
      dead_letters = {
        {
          delivery_id = "dead-1",
          queue = "devloop_ready",
          tag = "DEAD_LETTER",
          dead_at_ms = generated_at_ms - 60000,
        },
      },
    }, "dead-letter:devloop_ready")
  end,

  test_runtime_health_stale_dead_letter_audit_does_not_block_promotion = function()
    assert_clean({
      schema_version = 1,
      generated_at_ms = 1781832600000,
      truncated = { deliveries = false, dead_letters = false },
      queues = {
        { queue = "devloop_ready", depth = 0, pending = 0, in_flight = 0, retrying = 0, dlq = 1 },
      },
      dead_letters = {
        {
          delivery_id = "dead-1",
          queue = "devloop_ready",
          dead_at_ms = 1781830799999,
          permanent = true,
          replayable = false,
        },
      },
    })
  end,

  test_runtime_health_unageable_queue_dlq_snapshot_fails_closed = function()
    assert_dirty({
      queues = {
        { queue = "devloop_ready", ready = 0, leased = 0, retry = 0, dlq = 1 },
      },
    }, "dead-letter-detail-incomplete:queue=devloop_ready:count=1:detail=0")
  end,

  test_runtime_health_recent_terminal_fact_snapshot_is_dirty = function()
    assert_dirty({
      failure_facts = {
        {
          origin_queue = "devloop_fixing",
          origin_dept = "github-devloop.fix",
          error_class = "framework_child_nonzero",
          fingerprint = "framework_child_nonzero:ghi",
          terminal = true,
          observed_at_ms = generated_at_ms - 60000,
        },
      },
    }, "terminal-failure:devloop_fixing")
  end,

  test_runtime_health_stale_terminal_fact_does_not_block_promotion = function()
    assert_clean({
      failure_facts = {
        {
          origin_queue = "devloop_fixing",
          origin_dept = "github-devloop.fix",
          terminal = true,
          observed_at_ms = generated_at_ms - 1800001,
        },
      },
    })
  end,

  test_runtime_health_unageable_terminal_fact_fails_closed = function()
    assert_dirty({
      failure_facts = {
        {
          origin_queue = "devloop_fixing",
          origin_dept = "github-devloop.fix",
          terminal = true,
        },
      },
    }, "failure-fact-time-invalid:devloop_fixing")
  end,

  test_runtime_health_unageable_dead_letter_fails_closed = function()
    assert_dirty({
      dead_letters = {
        { delivery_id = "dead-1", queue = "devloop_ready" },
      },
    }, "dead-letter-time-invalid:devloop_ready")
  end,

  test_runtime_health_truncated_dead_letter_detail_fails_closed = function()
    assert_dirty({
      truncated = { deliveries = false, dead_letters = true },
      dead_letters = {
        { delivery_id = "dead-1", queue = "devloop_ready", dead_at_ms = generated_at_ms - 1800001 },
      },
    }, "dead-letter-detail-truncated")
  end,

  test_runtime_health_stalled_entity_snapshot_is_dirty = function()
    assert_dirty({
      entities = {
        {
          entity = "github-devloop/issue/owner/repo/623",
          terminal = false,
          events = {
            {
              queue = "devloop_ready",
              ts = "2026-06-14T09:20:00Z",
            },
          },
        },
      },
    }, "stalled-entity:github-devloop/issue/owner/repo/623")
  end,

  test_runtime_health_empty_entities_uses_fallback_timeline = function()
    assert_dirty({
      entities = {},
      entity_timeline = {
        {
          entity = "github-devloop/issue/owner/repo/624",
          terminal = false,
          events = {
            {
              queue = "devloop_ready",
              ts = "2026-06-14T09:20:00Z",
            },
          },
        },
      },
    }, "stalled-entity:github-devloop/issue/owner/repo/624")
  end,

  test_runtime_health_malformed_snapshot_fails_closed = function()
    assert_dirty("not a snapshot", "observe-malformed")
  end,

  test_runtime_observe_gate_maps_unavailable_and_malformed_to_visible_hold_reason = function()
    local unavailable_ok, unavailable_reason, unavailable_detail = runtime_health.runtime_observe_gate({
      clean = false,
      reason = "observe-unavailable",
    })
    t.eq(unavailable_ok, false)
    t.eq(unavailable_reason, "observe-unavailable")
    t.eq(unavailable_detail, "observe-unavailable")

    local malformed_ok, malformed_reason, malformed_detail = runtime_health.runtime_observe_gate({
      clean = false,
      reason = "observe-malformed",
    })
    t.eq(malformed_ok, false)
    t.eq(malformed_reason, "observe-unavailable")
    t.eq(malformed_detail, "observe-malformed")
  end,
}
