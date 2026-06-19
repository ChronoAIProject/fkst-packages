local t = fkst.test

local function opts(name)
  return {
    env = {
      FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/idle-detector/" .. tostring(name),
    },
  }
end

local function event(ts)
  local slot = ts or "1970-01-01T00:00:00Z"
  return {
    queue = "idle_tick",
    ts = slot,
    payload = {
      schema = "idle-detector.idle-tick.v1",
      slot = slot,
      source_ref = { kind = "cron", ref = "idle-detector/idle_poll/" .. slot },
    },
  }
end

local function mock_observe(stdout, exit_code)
  t.mock_command("fkst-framework observe --json", {
    stdout = stdout or "",
    stderr = exit_code == 0 and "" or "observe failed",
    exit_code = exit_code or 0,
  })
end

local function idle_observe_json()
  return '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":0,"leased":0,"retry":0,"dlq":0}],"anomalies":[],"dlq":[]}'
end

local function assert_skip_with_observe(case_name, observe_stdout, exit_code)
  mock_observe(observe_stdout, exit_code or 0)
  local result = t.run_department("departments/idle_gate/main.lua", event("1970-01-01T00:00:00Z"), opts(case_name))
  t.eq(result.exit_code, 0)
  t.eq(#result.raises, 0)
end

return {
  test_idle_gate_drops_stale_cron_slot = function()
    local result = t.run_department("departments/idle_gate/main.lua", event("1970-01-01T00:00:00Z"), opts("stale"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(#t.command_calls(), 0)
  end,

  -- The engine department harness exposes real now() but no now injection, and
  -- this worker's observed BIN exposes no observe snapshot timestamp to use as
  -- a deterministic reference clock. Fresh/stale precision stays in pure helper
  -- tests; this department test proves now-independent stale routing.
  test_idle_gate_drops_stale_cron_slot_even_when_observe_is_idle = function()
    mock_observe(idle_observe_json(), 0)
    local result = t.run_department("departments/idle_gate/main.lua", event("1970-01-01T00:00:00Z"), opts("stale-idle-observe"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_idle_gate_skips_observe_derived_busy_states = function()
    for _, case in ipairs({
      {
        name = "ready",
        observe = '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":1,"leased":0,"retry":0,"dlq":0}],"anomalies":[],"dlq":[]}',
      },
      {
        name = "leased",
        observe = '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":0,"leased":1,"retry":0,"dlq":0}],"anomalies":[],"dlq":[]}',
      },
      {
        name = "retry",
        observe = '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":0,"leased":0,"retry":1,"dlq":0}],"anomalies":[],"dlq":[]}',
      },
    }) do
      assert_skip_with_observe("busy-" .. case.name, case.observe, 0)
    end
  end,

  test_idle_gate_skips_dlq_or_anomaly_observe_facts = function()
    assert_skip_with_observe("dlq", '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":0,"leased":0,"retry":0,"dlq":0}],"anomalies":[],"dlq":[{"queue":"proposal"}]}', 0)
    assert_skip_with_observe("anomaly", '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":0,"leased":0,"retry":0,"dlq":0}],"anomalies":[{"type":"stalled"}],"dlq":[]}', 0)
  end,

  test_idle_gate_skips_observe_read_failure = function()
    assert_skip_with_observe("observe-failure", "", 1)
  end,

  test_idle_gate_skips_malformed_observe_shapes = function()
    for _, case in ipairs({
      {
        name = "non-table-queues",
        observe = '{"schema":"fkst.observe.v1","queues":"bad","anomalies":[],"dlq":[]}',
      },
      {
        name = "keyed-queues",
        observe = '{"schema":"fkst.observe.v1","queues":{"proposal":{"ready":0,"leased":0,"retry":0,"dlq":0}},"anomalies":[],"dlq":[]}',
      },
      {
        name = "keyed-anomalies",
        observe = '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":0,"leased":0,"retry":0,"dlq":0}],"anomalies":{"stalled":{"queue":"proposal"}},"dlq":[]}',
      },
      {
        name = "keyed-dlq",
        observe = '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":0,"leased":0,"retry":0,"dlq":0}],"anomalies":[],"dlq":{"proposal":{"count":1}}}',
      },
    }) do
      assert_skip_with_observe("malformed-" .. case.name, case.observe, 0)
    end
  end,

  test_idle_gate_skips_missing_or_ambiguous_queue_metric_groups = function()
    for _, case in ipairs({
      {
        name = "missing-ready",
        observe = '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","leased":0,"retry":0,"dlq":0}],"anomalies":[],"dlq":[]}',
      },
      {
        name = "ambiguous-ready",
        observe = '{"schema":"fkst.observe.v1","queues":[{"queue":"proposal","ready":0,"pending":0,"leased":0,"retry":0,"dlq":0}],"anomalies":[],"dlq":[]}',
      },
    }) do
      assert_skip_with_observe("metric-" .. case.name, case.observe, 0)
    end
  end,
}
