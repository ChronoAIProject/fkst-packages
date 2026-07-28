local activation = require("devloop.intake_replay_activation")
local t = fkst.test

local source_ref = {
  kind = "external",
  ref = "owner/repo#issue/42",
}

local function snapshot(deliveries, dead_letters)
  return {
    truncated = { deliveries = false, dead_letters = false },
    deliveries = deliveries or {},
    dead_letters = dead_letters or {},
  }
end

local function terminal(delivery_id, attempts, dead_at_ms)
  return {
    delivery_id = delivery_id,
    queue = activation.target_queue,
    dept = activation.target_dept,
    source = { kind = source_ref.kind, reference = source_ref.ref },
    attempts = attempts,
    permanent = true,
    replayable = false,
    dead_at_ms = dead_at_ms,
  }
end

local function live(delivery_id, status)
  return {
    delivery_id = delivery_id,
    queue = activation.target_queue,
    dept = activation.target_dept,
    source = { kind = source_ref.kind, reference = source_ref.ref },
    status = status,
  }
end

return {
  test_observation_key_uses_latest_terminal_and_live_ground_state = function()
    local older = terminal("delivery/old", 1, 100)
    local latest = terminal("delivery/new", 2, 200)
    local active = live("delivery/live", "in-flight")

    local key, reason = activation.observation_key(snapshot({ active }, { latest, older }), source_ref)
    t.is_nil(reason)
    t.eq(
      key,
      "intake-replay-observation/external/owner/repo#issue/42/terminal/delivery/new/attempts/2/live-present"
    )

    local selected, blocked = activation.terminal_precondition(snapshot({ active }, { latest, older }), source_ref)
    t.is_nil(selected)
    t.eq(blocked, "live-delivery-present")

    selected, blocked = activation.terminal_precondition(snapshot(nil, { latest, older }), source_ref)
    t.eq(selected.delivery_id, latest.delivery_id)
    t.is_nil(blocked)
  end,

  test_observe_snapshot_validation_fails_closed_on_truncation = function()
    local valid, reason = activation.validate_snapshot({
      truncated = { deliveries = false, dead_letters = true },
      deliveries = {},
      dead_letters = {},
    })
    t.is_nil(valid)
    t.eq(reason, "observe-truncated")
  end,
}
