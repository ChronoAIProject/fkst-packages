local core = require("core")
local t = fkst.test

local function observe_idle()
  return {
    schema = "fkst.observe.v1",
    queues = {
      { queue = "idle_tick", ready = 0, leased = 0, retry = 0, dlq = 0 },
      { queue = "github_poll_tick", pending = 0, inflight = 0, delayed = 0, dead_letters = 0 },
    },
    anomalies = {},
    dlq = {},
  }
end

return {
  test_idle_predicate_accepts_zero_queue_and_empty_anomalies = function()
    local idle, why = core.is_idle_observe(observe_idle())
    t.eq(idle, true)
    t.is_nil(why)
  end,

  test_idle_predicate_fails_closed_on_missing_required_fact_groups = function()
    local facts = observe_idle()
    facts.queues = nil
    t.raises(function() core.is_idle_observe(facts) end)
    facts = observe_idle()
    facts.anomalies = nil
    t.raises(function() core.is_idle_observe(facts) end)
    facts = observe_idle()
    facts.dlq = nil
    t.raises(function() core.is_idle_observe(facts) end)
  end,

  test_idle_predicate_fails_closed_on_unknown_schema = function()
    local facts = observe_idle()
    facts.schema = "fkst.observe.v2"
    t.raises(function() core.is_idle_observe(facts) end)
  end,

  test_idle_predicate_fails_closed_on_malformed_top_level = function()
    t.raises(function() core.is_idle_observe("not facts") end)
    local facts = observe_idle()
    facts.queues = "not a table"
    t.raises(function() core.is_idle_observe(facts) end)
  end,

  test_idle_predicate_fails_closed_on_non_dense_observe_lists = function()
    for _, list_name in ipairs({ "queues", "anomalies", "dlq" }) do
      local keyed = observe_idle()
      keyed[list_name] = { keyed = {} }
      t.raises(function() core.is_idle_observe(keyed) end)

      local sparse = observe_idle()
      sparse[list_name] = {}
      sparse[list_name][1] = {}
      sparse[list_name][3] = {}
      t.raises(function() core.is_idle_observe(sparse) end)
    end
  end,

  test_idle_predicate_rejects_ready_work = function()
    local facts = observe_idle()
    facts.queues[1].ready = 1
    local idle, why = core.is_idle_observe(facts)
    t.eq(idle, false)
    t.is_true(why:find("ready", 1, true) ~= nil)
  end,

  test_idle_predicate_rejects_leased_retry_and_dlq = function()
    for field, _value in pairs({ leased = 1, retry = 1, dlq = 1 }) do
      local facts = observe_idle()
      facts.queues[1][field] = 1
      local idle, why = core.is_idle_observe(facts)
      t.eq(idle, false)
      t.is_true(why:find(field, 1, true) ~= nil)
    end
  end,

  test_idle_predicate_fails_closed_on_missing_each_busy_dimension_group = function()
    for _, field in ipairs({ "ready", "leased", "retry", "dlq" }) do
      local facts = observe_idle()
      facts.queues[1][field] = nil
      t.raises(function() core.is_idle_observe(facts) end)
    end
  end,

  test_idle_predicate_fails_closed_on_ambiguous_and_unknown_metric_groups = function()
    local facts = observe_idle()
    facts.queues[1].pending = 0
    t.raises(function() core.is_idle_observe(facts) end)
    facts = observe_idle()
    facts.queues[1] = { queue = "proposal", unexpected = 0 }
    t.raises(function() core.is_idle_observe(facts) end)
  end,

  test_idle_predicate_rejects_anomalies = function()
    local facts = observe_idle()
    facts.anomalies = { { type = "terminal-failure", queue = "demo" } }
    local idle, why = core.is_idle_observe(facts)
    t.eq(idle, false)
    t.is_true(why:find("anomaly", 1, true) ~= nil)
  end,

  test_observe_wrapper_parses_json = function()
    local observed = core.observe(function(cmd)
      t.eq(cmd.cmd, "fkst-framework observe --json")
      t.eq(cmd.timeout, 30)
      return {
        stdout = '{"schema":"fkst.observe.v1","queues":[],"anomalies":[],"dlq":[]}',
        stderr = "",
        exit_code = 0,
      }
    end)
    t.eq(observed.schema, "fkst.observe.v1")
  end,

  test_observe_wrapper_fails_closed_on_unknown_schema = function()
    t.raises(function()
      core.observe(function(_cmd)
        return {
          stdout = '{"schema":"fkst.observe.v2","queues":[],"anomalies":[],"dlq":[]}',
          stderr = "",
          exit_code = 0,
        }
      end)
    end)
  end,

  test_observe_wrapper_fails_closed_on_command_failure = function()
    t.raises(function()
      core.observe(function(_cmd)
        return { stdout = "", stderr = "boom", exit_code = 1 }
      end)
    end)
  end,

  test_system_idle_payload_is_small_and_source_ref_backed = function()
    local payload = core.build_system_idle_payload("2026-06-19T01:00:00Z", "idle_tick/2026-06-19T01:00:00Z", "2026-06-19T01:10:00Z")
    t.eq(payload.schema, "idle-detector.system-idle.v1")
    t.eq(payload.detected_at, "2026-06-19T01:00:00Z")
    t.eq(payload.source_ref.kind, "host-observe")
    t.eq(payload.source_ref.ref, "idle_tick/2026-06-19T01:00:00Z")
    t.eq(payload.expires_at, "2026-06-19T01:10:00Z")
    t.is_nil(payload.queues)
    t.is_nil(payload.metrics)
  end,

  test_freshness_verdict_is_pure_and_deterministic = function()
    local reference = core.iso_timestamp_epoch_seconds("2026-06-19T01:00:00Z")
    t.eq(core.freshness_verdict(reference, reference + 60, 600), "fresh")
    t.eq(core.freshness_verdict(reference, reference + 600, 600), "fresh")
    t.eq(core.freshness_verdict(reference, reference + 601, 600), "stale")
    t.eq(core.freshness_verdict(reference, reference - 60, 600), "fresh")
    t.raises(function() core.freshness_verdict(nil, reference, 600) end)
  end,

  test_skip_fact_fields_are_pure_and_structured = function()
    for _, case in ipairs({
      { why = "busy queue=proposal ready=1" },
      { why = "busy dlq>0" },
      { why = "unreadable observe facts: observe failed" },
      { why = "malformed observe facts: missing metric group" },
      { why = "stale idle_tick slot" },
    }) do
      local fact = core.skip_fact("idle_gate", {
        queue = "idle_tick",
        payload = {
          source_ref = { kind = "cron", ref = "idle-detector/idle_poll/2099-01-01T00:00:00Z" },
        },
      }, case.why, true)
      t.is_true(fact:find("tag=SKIP", 1, true) ~= nil)
      t.is_true(fact:find("error_class=terminal-skip", 1, true) ~= nil)
      t.is_true(fact:find("source_ref=cron:idle-detector/idle_poll/2099-01-01T00:00:00Z", 1, true) ~= nil)
      t.is_true(fact:find("terminal=true", 1, true) ~= nil)
      t.is_true(fact:find("WHY=" .. case.why, 1, true) ~= nil)
    end
  end,
}
