local base_ids = require("devloop.base_ids")
local entity_list_cache = require("devloop.entity_list_cache")
local replay_authorization = require("core.replay_authorization")
local admission_department = require("departments.admission.main")
local h = require("tests.devloop_helpers")
local testing = require("testkit_internal.testing")
local t = fkst.test

local repo = "poll-index-owner/repo"
local target_queue = "github-devloop-intake.devloop_intake_candidate"
local target_dept = "github-devloop-intake-default.intake_judge"

local function source_ref(selected_repo, number)
  return base_ids.issue_source_ref(selected_repo or repo, number)
end

local function source_row(selected_repo, number)
  return {
    kind = "external",
    reference = source_ref(selected_repo, number).ref,
  }
end

local function live_row(selected_repo, number)
  return {
    delivery_id = "target-live-" .. tostring(number),
    queue = target_queue,
    dept = target_dept,
    source = source_row(selected_repo, number),
    status = "retrying",
  }
end

local function terminal_row(selected_repo, number, delivery_id)
  return {
    delivery_id = delivery_id or ("target-dead-" .. tostring(number)),
    queue = target_queue,
    dept = target_dept,
    source = source_row(selected_repo, number),
    attempts = 3,
    permanent = true,
    replayable = false,
    dead_at_ms = 2000,
  }
end

local function snapshot(selected_repo)
  local deliveries = {}
  local dead_letters = {}
  for number = 1000, 1099 do
    table.insert(deliveries, {
      delivery_id = "noise-live-" .. tostring(number),
      queue = "other.queue",
      dept = "other.department",
      source = source_row(selected_repo, number),
      status = "pending",
    })
    table.insert(dead_letters, {
      delivery_id = "noise-dead-" .. tostring(number),
      queue = "other.queue",
      dept = "other.department",
      source = source_row(selected_repo, number),
      attempts = 1,
      permanent = true,
      replayable = false,
      dead_at_ms = number,
    })
  end
  table.insert(deliveries, live_row(selected_repo, 43))
  table.insert(dead_letters, terminal_row(selected_repo, 42))
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
  test_replay_authorization_builds_one_screening_index_per_current_poll_epoch = function()
    cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
    local recorded, first_epoch = entity_list_cache.record_poll_epoch(repo, "2026-08-03T01:00:00Z")
    t.is_true(recorded)

    local observe_calls = 0
    local authorization = replay_authorization.make({
      observe = function(opts)
        observe_calls = observe_calls + 1
        t.eq(opts.limit, 10000)
        return snapshot(repo)
      end,
    })

    local terminal, reason, targeted = authorization.terminal_precondition(source_ref(repo, 42), first_epoch)
    t.eq(observe_calls, 1)
    t.eq(reason, nil)
    t.is_true(type(targeted) == "table")
    t.eq(#targeted.dead_letters, 1)
    t.eq(terminal.delivery_id, "target-dead-42")
    t.eq(terminal.attempts, 3)

    local live_terminal, live_reason = authorization.terminal_precondition(source_ref(repo, 43), first_epoch)
    t.eq(live_terminal, nil)
    t.eq(live_reason, "live-delivery-present")

    local absent_terminal, absent_reason = authorization.terminal_precondition(source_ref(repo, 44), first_epoch)
    t.eq(absent_terminal, nil)
    t.eq(absent_reason, "terminal-dlq-absent")
    t.eq(observe_calls, 1)

    local advanced, second_epoch = entity_list_cache.record_poll_epoch(repo, "2026-08-03T01:05:00Z")
    t.is_true(advanced)
    local next_terminal = authorization.terminal_precondition(source_ref(repo, 42), second_epoch)
    t.eq(next_terminal.delivery_id, "target-dead-42")
    t.eq(observe_calls, 2)

    local stale_terminal, stale_reason = authorization.terminal_precondition(source_ref(repo, 42), first_epoch)
    t.eq(stale_terminal, nil)
    t.eq(stale_reason, "observe-stale-poll-epoch")
    t.eq(observe_calls, 2)
  end,

  test_failed_screening_snapshot_is_settled_once_per_poll_epoch = function()
    local failed_repo = "poll-index-failure/repo"
    cache_set(entity_list_cache.poll_epoch_cache_key(failed_repo), "")
    local recorded, poll_epoch = entity_list_cache.record_poll_epoch(failed_repo, "2026-08-03T02:00:00Z")
    t.is_true(recorded)

    local observe_calls = 0
    local observe_is_truncated = true
    local authorization = replay_authorization.make({
      observe = function()
        observe_calls = observe_calls + 1
        local observed = snapshot(failed_repo)
        observed.truncated.deliveries = observe_is_truncated
        return observed
      end,
    })

    local first_terminal, first_reason = authorization.terminal_precondition(
      source_ref(failed_repo, 42),
      poll_epoch
    )
    local second_terminal, second_reason = authorization.terminal_precondition(
      source_ref(failed_repo, 43),
      poll_epoch
    )

    t.eq(first_terminal, nil)
    t.eq(first_reason, "observe-truncated")
    t.eq(second_terminal, nil)
    t.eq(second_reason, "observe-truncated")
    t.eq(observe_calls, 1)

    observe_is_truncated = false
    local advanced, next_epoch = entity_list_cache.record_poll_epoch(failed_repo, "2026-08-03T02:05:00Z")
    t.is_true(advanced)
    local recovered_terminal, recovered_reason = authorization.terminal_precondition(
      source_ref(failed_repo, 42),
      next_epoch
    )
    t.eq(recovered_reason, nil)
    t.eq(recovered_terminal.delivery_id, "target-dead-42")
    t.eq(observe_calls, 2)
  end,

  test_selected_terminal_candidate_is_revalidated_from_current_lineage = function()
    local selected_repo = "poll-index-revalidate/repo"
    local expected_terminal = terminal_row(selected_repo, 42)
    local observe_calls = 0
    local authorization = replay_authorization.make({
      observe = function(opts)
        observe_calls = observe_calls + 1
        t.is_true(type(opts.lineage) == "table")
        t.eq(opts.lineage.queue, target_queue)
        t.eq(opts.lineage.dept, target_dept)
        t.eq(opts.lineage.source_ref.ref, source_ref(selected_repo, 42).ref)
        return {
          live_delivery = live_row(selected_repo, 42),
          terminal_dead_letter = expected_terminal,
        }
      end,
    })

    local permitted, reason = authorization.revalidate(source_ref(selected_repo, 42), expected_terminal)

    t.eq(permitted, false)
    t.eq(reason, "live-delivery-present")
    t.eq(observe_calls, 1)
  end,

  test_admission_drops_terminal_candidate_that_becomes_live_inside_once = function()
    local selected_repo = "poll-index-effect/repo"
    local issue_number = 42
    local observed_source = source_ref(selected_repo, issue_number)
    local expected_terminal = terminal_row(selected_repo, issue_number)
    cache_set(entity_list_cache.poll_epoch_cache_key(selected_repo), "")
    local recorded, poll_epoch = entity_list_cache.record_poll_epoch(
      selected_repo,
      "2026-08-03T03:00:00Z"
    )
    t.is_true(recorded)
    h.mock_bot_env()

    local observe_calls = 0
    local inside_once = false
    local authorization = replay_authorization.make({
      observe = function(opts)
        observe_calls = observe_calls + 1
        if opts.lineage ~= nil then
          t.is_true(inside_once, "delivery lineage must be revalidated inside once")
          return {
            live_delivery = live_row(selected_repo, issue_number),
            terminal_dead_letter = expected_terminal,
          }
        end
        return {
          schema_version = 1,
          limits = { max_deliveries = 10000, max_dead_letters = 10000 },
          truncated = { deliveries = false, dead_letters = false },
          queues = {},
          deliveries = {},
          dead_letters = { expected_terminal },
        }
      end,
    })
    local capacity = { authorized = 0, reconciled = 0 }
    local department = admission_department.make_department({
      replay_authorization = authorization,
      read_current_issue = function()
        return selected_repo, issue_number, {
          number = issue_number,
          title = "Replay candidate",
          body = "",
          state = "OPEN",
          labels = {},
          comments = {},
          assignees = { "fkst-test-bot" },
        }
      end,
      capacity = {
        authorize = function()
          capacity.authorized = capacity.authorized + 1
          return true, "test capacity"
        end,
        reconcile = function()
          capacity.reconciled = capacity.reconciled + 1
          return true, "test capacity reconciled"
        end,
      },
    })

    local event = {
      queue = "github-proxy.github_issue_observed",
      payload = {
        schema = "github-proxy.issue-observed.v1",
        type = "issue",
        repo = selected_repo,
        number = issue_number,
        updated_at = "2026-08-03T03:00:00Z",
        dedup_key = "github-issue-observed/poll-index-effect/repo/42/2026-08-03T03:00:00Z",
        poll_token = poll_epoch,
        source_ref = observed_source,
      },
      source_ref = observed_source,
    }

    local original_once = once
    once = function(_key, fn)
      inside_once = true
      local ok, err = pcall(fn)
      inside_once = false
      if not ok then
        error(err, 0)
      end
      return true
    end
    local ok, result = pcall(function()
      return testing.run_fake_outcome(department, event)
    end)
    once = original_once
    if not ok then
      error(result, 0)
    end

    t.eq(result.exit_code, 0, tostring(result.error))
    t.eq(#result.raises, 0)
    t.eq(observe_calls, 2)
    t.eq(capacity.authorized, 1)
    t.eq(capacity.reconciled, 1)
  end,
}
