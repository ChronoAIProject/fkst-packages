local sha256 = require("contract.sha256")
local t = fkst.test

local queue = "github-proxy.github_entity_changed"
local base_key = "owner/x#issue#50@2026-06-03T01:04:00Z"
local terminal_id = "delivery/v3/raised/queue/github-proxy.github_entity_changed/dept/github-devloop-intake.admission/dedup/base"

local function payload_summary(dedup_key)
  return {
    schema = "github-proxy.v1",
    dedup_key = dedup_key,
    digest = string.rep("a", 64),
    bytes = 128,
  }
end

local function source()
  return {
    kind = "cron",
    reference = "github-proxy.github_poll/slot/1785574800000",
  }
end

local function live_row(dedup_key)
  return {
    delivery_id = "live-delivery",
    queue = queue,
    dept = "github-devloop-intake.admission",
    source = source(),
    status = "in-flight",
    observed_at_ms = 1785574800000,
    not_before_ms = 1785574800000,
    attempt = 0,
    redrive_count = 0,
    lease_generation = 1,
    lease_until_ms = 1785574830000,
    fence_token = "live-delivery#1",
    subscriber_absent_since_ms = nil,
    payload = payload_summary(dedup_key),
    last_error_excerpt = nil,
  }
end

local function terminal_row()
  return {
    delivery_id = terminal_id,
    queue = queue,
    dept = "github-devloop-intake.admission",
    source = source(),
    observed_at_ms = 1785574800000,
    not_before_ms = 1785574800000,
    dead_at_ms = 1785574860000,
    attempts = 3,
    redrive_count = 3,
    replayable = false,
    permanent = true,
    payload = payload_summary(base_key),
    error_excerpt = "transient admission failure",
  }
end

local function snapshot(deliveries, dead_letters)
  return {
    schema_version = 1,
    generated_at_ms = 1785574920000,
    source = {
      durable_root = "/tmp/fkst-durable",
      database = "/tmp/fkst-durable/delivery.redb",
      read_semantics = "single read transaction",
      history_semantics = "mutable delivery queue snapshot",
    },
    limits = { max_deliveries = 10000, max_dead_letters = 10000 },
    truncated = { deliveries = false, dead_letters = false },
    queues = {},
    deliveries = deliveries or {},
    dead_letters = dead_letters or {},
  }
end

local function load_rearm()
  local ok, module = pcall(require, "core.poll_delivery_rearm")
  t.is_true(ok, tostring(module))
  return module
end

return {
  test_terminal_delivery_advances_to_one_deterministic_rearm_generation = function()
    local rearm = load_rearm()
    local index = rearm.index(snapshot({}, { terminal_row() }))

    t.eq(
      index.key_for(queue, base_key),
      base_key .. "/rearm/" .. sha256.hex(terminal_id)
    )
  end,

  test_live_rearm_generation_is_reused_instead_of_creating_another_generation = function()
    local rearm = load_rearm()
    local rearm_key = base_key .. "/rearm/" .. sha256.hex(terminal_id)
    local index = rearm.index(snapshot({ live_row(rearm_key) }, { terminal_row() }))

    t.eq(index.key_for(queue, base_key), rearm_key)
  end,

  test_truncated_delivery_snapshot_fails_closed = function()
    local rearm = load_rearm()
    local truncated = snapshot({}, { terminal_row() })
    truncated.truncated.dead_letters = true

    local ok, err = pcall(rearm.index, truncated)
    t.eq(ok, false)
    t.is_true(tostring(err):find("observe-truncated", 1, true) ~= nil)
  end,

  test_current_truncated_snapshot_falls_back_to_the_base_generation = function()
    local rearm = load_rearm()
    local truncated = snapshot(json.decode("[]"), { terminal_row() })
    truncated.truncated.dead_letters = true
    t.mock_observe(truncated)

    local index = rearm.current({ queue })

    t.eq(index.key_for(queue, base_key), base_key)
  end,
}
