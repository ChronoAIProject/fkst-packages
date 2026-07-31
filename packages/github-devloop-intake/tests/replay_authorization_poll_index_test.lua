local base_ids = require("devloop.base_ids")
local entity_list_cache = require("devloop.entity_list_cache")
local replay_authorization = require("core.replay_authorization")
local t = fkst.test

local repo = "poll-index-owner/repo"
local target_queue = "github-devloop-intake.devloop_intake_candidate"
local target_dept = "github-devloop-intake-default.intake_judge"

local function source_ref(number)
  return base_ids.issue_source_ref(repo, number)
end

local function source_row(number)
  return {
    kind = "external",
    reference = source_ref(number).ref,
  }
end

local function snapshot()
  local deliveries = {}
  local dead_letters = {}
  for number = 1000, 1099 do
    table.insert(deliveries, {
      delivery_id = "noise-live-" .. tostring(number),
      queue = "other.queue",
      dept = "other.department",
      source = source_row(number),
      status = "pending",
    })
    table.insert(dead_letters, {
      delivery_id = "noise-dead-" .. tostring(number),
      queue = "other.queue",
      dept = "other.department",
      source = source_row(number),
      attempts = 1,
      permanent = true,
      replayable = false,
      dead_at_ms = number,
    })
  end
  table.insert(deliveries, {
    delivery_id = "target-live-43",
    queue = target_queue,
    dept = target_dept,
    source = source_row(43),
    status = "retrying",
  })
  table.insert(dead_letters, {
    delivery_id = "target-dead-42",
    queue = target_queue,
    dept = target_dept,
    source = source_row(42),
    attempts = 3,
    permanent = true,
    replayable = false,
    dead_at_ms = 2000,
  })
  return {
    schema_version = 1,
    limits = { max_deliveries = 10000, max_dead_letters = 10000 },
    truncated = { deliveries = false, dead_letters = false },
    queues = {},
    deliveries = deliveries,
    dead_letters = dead_letters,
  }
end

return {
  test_replay_authorization_builds_one_targeted_index_per_current_poll_epoch = function()
    cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
    local recorded, first_epoch = entity_list_cache.record_poll_epoch(repo, "2026-07-31T01:00:00Z")
    t.is_true(recorded)

    local observe_calls = 0
    local authorization = replay_authorization.make({
      observe = function(opts)
        observe_calls = observe_calls + 1
        t.eq(opts.limit, 10000)
        return snapshot()
      end,
    })

    local terminal, reason, targeted = authorization.terminal_precondition(source_ref(42), first_epoch)
    t.eq(observe_calls, 1)
    t.eq(reason, nil)
    assert(
      type(targeted) == "table",
      "targeted snapshot missing: reason=" .. tostring(reason) .. " observe_calls=" .. tostring(observe_calls)
    )
    t.eq(#targeted.dead_letters, 1)
    t.eq(terminal.delivery_id, "target-dead-42")
    t.eq(terminal.attempts, 3)

    local live_terminal, live_reason = authorization.terminal_precondition(source_ref(43), first_epoch)
    t.eq(live_terminal, nil)
    t.eq(live_reason, "live-delivery-present")

    local absent_terminal, absent_reason = authorization.terminal_precondition(source_ref(44), first_epoch)
    t.eq(absent_terminal, nil)
    t.eq(absent_reason, "terminal-dlq-absent")
    t.eq(observe_calls, 1)

    local advanced, second_epoch = entity_list_cache.record_poll_epoch(repo, "2026-07-31T01:05:00Z")
    t.is_true(advanced)
    local next_terminal = authorization.terminal_precondition(source_ref(42), second_epoch)
    t.eq(next_terminal.delivery_id, "target-dead-42")
    t.eq(observe_calls, 2)

    local stale_terminal, stale_reason = authorization.terminal_precondition(source_ref(42), first_epoch)
    t.eq(stale_terminal, nil)
    t.eq(stale_reason, "observe-stale-poll-epoch")
    t.eq(observe_calls, 2)
  end,

  test_failed_observe_snapshot_is_settled_once_per_poll_epoch = function()
    local failed_repo = "poll-index-failure/repo"
    cache_set(entity_list_cache.poll_epoch_cache_key(failed_repo), "")
    local recorded, poll_epoch = entity_list_cache.record_poll_epoch(failed_repo, "2026-07-31T02:00:00Z")
    t.is_true(recorded)

    local observe_calls = 0
    local observe_is_truncated = true
    local authorization = replay_authorization.make({
      observe = function()
        observe_calls = observe_calls + 1
        local truncated = snapshot()
        truncated.truncated.deliveries = observe_is_truncated
        return truncated
      end,
    })

    local first_terminal, first_reason = authorization.terminal_precondition(
      base_ids.issue_source_ref(failed_repo, 42),
      poll_epoch
    )
    local second_terminal, second_reason = authorization.terminal_precondition(
      base_ids.issue_source_ref(failed_repo, 43),
      poll_epoch
    )

    t.eq(first_terminal, nil)
    t.eq(first_reason, "observe-truncated")
    t.eq(second_terminal, nil)
    t.eq(second_reason, "observe-truncated")
    t.eq(observe_calls, 1)

    observe_is_truncated = false
    local advanced, next_epoch = entity_list_cache.record_poll_epoch(failed_repo, "2026-07-31T02:05:00Z")
    t.is_true(advanced)
    local recovered_terminal, recovered_reason = authorization.terminal_precondition(
      base_ids.issue_source_ref(failed_repo, 42),
      next_epoch
    )
    t.eq(recovered_terminal, nil)
    t.eq(recovered_reason, "terminal-dlq-absent")
    t.eq(observe_calls, 2)
  end,
}
