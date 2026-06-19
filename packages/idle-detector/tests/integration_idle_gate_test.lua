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

return {
  test_idle_gate_drops_stale_cron_slot = function()
    local result = t.run_department("departments/idle_gate/main.lua", event("1970-01-01T00:00:00Z"), opts("stale"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(#t.command_calls(), 0)
  end,
}
