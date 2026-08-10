local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t
local gh_argv = require("testkit_internal.gh_argv_mock")
local entity_list_cache = require("devloop.entity_list_cache")
local author_policy = require("testkit_internal.github_author_policy")

local function count_calls(needle)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if gh_argv.call_contains(call, needle) then
      count = count + 1
    end
  end
  return count
end

return {
  test_entity_list_poll_key_prefers_explicit_token_and_preserves_fallbacks = function()
    t.eq(entity_list_cache.entity_list_poll_key({
      ts = "event-ts",
      payload = { poll_token = "explicit-token", tick = "payload-tick" },
    }), "explicit-token")
    t.eq(entity_list_cache.entity_list_poll_key({
      ts = "event-ts",
      payload = { tick = "payload-tick" },
    }), "event-ts")
    t.eq(entity_list_cache.entity_list_poll_key({ payload = { tick = "payload-tick" } }), "payload-tick")
    t.eq(entity_list_cache.entity_list_poll_key({ payload = { generated_at = "generated-at" } }), "generated-at")
    t.eq(entity_list_cache.entity_list_poll_key({ payload = { ts = "payload-ts" } }), "payload-ts")
    t.eq(entity_list_cache.entity_list_poll_key({ payload = {} }), nil)
  end,

  test_entity_list_cache_key_is_readable_and_scoped_to_exact_poll_key = function()
    local first = entity_list_cache.entity_list_cache_key("owner/repo", "issue", "open", "2026-06-03T01:02:03Z")
    local second = entity_list_cache.entity_list_cache_key("owner/repo", "issue", "open", "2026-06-03T01:02:04Z")
    local missing = entity_list_cache.entity_list_cache_key("owner/repo", "issue", "open", nil)

    t.is_true(first:find("^github%-devloop/entity%-list%-v2/owner/repo/issue/open/poll%-") ~= nil)
    t.eq(first == second, false)
    t.eq(missing, nil)
  end,

  test_run_if_current_poll_epoch_does_not_hold_the_writer_lock_while_running = function()
    local repo = "owner/lock-free-poll-guard"
    local lock_key = entity_list_cache.poll_epoch_cache_key(repo)
    cache_set(lock_key, "")
    local recorded, poll_epoch = entity_list_cache.record_poll_epoch(repo, "2026-08-10T01:02:03Z")
    t.is_true(recorded)

    local previous_with_lock = with_lock
    local epoch_lock_held = false
    local epoch_lock_acquisitions = 0
    with_lock = function(key, fn)
      if key ~= lock_key then
        return previous_with_lock(key, fn)
      end
      epoch_lock_acquisitions = epoch_lock_acquisitions + 1
      if epoch_lock_held then
        error("with_lock lock busy: " .. key)
      end
      epoch_lock_held = true
      local results = table.pack(pcall(fn))
      epoch_lock_held = false
      if not results[1] then
        error(results[2])
      end
      return table.unpack(results, 2, results.n)
    end

    local first_ran = false
    local second_ran = false
    local ok, err = pcall(function()
      local first_current = entity_list_cache.run_if_current_poll_epoch(repo, poll_epoch, function()
        first_ran = true
        local second_current = entity_list_cache.run_if_current_poll_epoch(repo, poll_epoch, function()
          second_ran = true
        end)
        t.is_true(second_current)
      end)
      t.is_true(first_current)
    end)
    with_lock = previous_with_lock

    t.is_true(ok, tostring(err))
    t.is_true(first_ran)
    t.is_true(second_ran)
    t.eq(epoch_lock_acquisitions, 0)
  end,

  test_run_if_current_poll_epoch_skips_a_stale_generation = function()
    local repo = "owner/stale-poll-guard"
    cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
    local older_recorded, older_epoch = entity_list_cache.record_poll_epoch(repo, "2026-08-10T01:02:03Z")
    local newer_recorded = entity_list_cache.record_poll_epoch(repo, "2026-08-10T01:02:04Z")
    t.is_true(older_recorded)
    t.is_true(newer_recorded)

    local ran = false
    local current, result = entity_list_cache.run_if_current_poll_epoch(repo, older_epoch, function()
      ran = true
      return "unexpected"
    end)

    t.eq(current, false)
    t.eq(result, nil)
    t.eq(ran, false)
  end,

  test_record_poll_epoch_keeps_monotonic_sub_epochs_under_the_writer_lock = function()
    local repo = "owner/poll-writer-lock"
    local lock_key = entity_list_cache.poll_epoch_cache_key(repo)
    cache_set(lock_key, "")
    local previous_with_lock = with_lock
    local acquired_keys = {}
    with_lock = function(key, fn)
      acquired_keys[#acquired_keys + 1] = key
      return fn()
    end

    local ok, first_recorded, first_epoch, second_recorded, second_epoch = pcall(function()
      local recorded_1, epoch_1 = entity_list_cache.record_poll_epoch(repo, "2026-08-10T01:02:03Z")
      local recorded_2, epoch_2 = entity_list_cache.record_poll_epoch(repo, "2026-08-10T01:02:03Z")
      return recorded_1, epoch_1, recorded_2, epoch_2
    end)
    with_lock = previous_with_lock

    t.is_true(ok)
    t.is_true(first_recorded)
    t.is_true(second_recorded)
    t.eq(first_epoch, "2026-08-10T01:02:03Z/sub-epoch/0")
    t.eq(second_epoch, "2026-08-10T01:02:03Z/sub-epoch/1")
    t.eq(#acquired_keys, 2)
    t.eq(acquired_keys[1], lock_key)
    t.eq(acquired_keys[2], lock_key)
  end,

  test_shared_issue_observe_list_reuses_only_the_same_poll_snapshot = function()
    author_policy.mock_env(t, nil, {
      configure_trusted_bot_login = h.mock_author_policy_configure,
    })
    local repo = "owner/shared-list"
    local command = core.gh_issue_list_observe_cmd(repo)
    t.mock_command(command, {
      stdout = '[{"number":42,"state":"open","updated_at":"2026-06-03T01:02:03Z"}]\n',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(command, {
      stdout = '[{"number":43,"state":"open","updated_at":"2026-06-03T01:03:03Z"}]\n',
      stderr = "",
      exit_code = 0,
    })

    local first = entity_list_cache.fetch_shared_issue_observe_list(core, repo, {
      poll_key = "2026-06-03T01:02:03Z",
    })
    local second = entity_list_cache.fetch_shared_issue_observe_list(core, repo, {
      poll_key = "2026-06-03T01:02:03Z",
    })
    local next_poll = entity_list_cache.fetch_shared_issue_observe_list(core, repo, {
      poll_key = "2026-06-03T01:03:03Z",
    })

    t.eq(first.exit_code, 0)
    t.eq(second.exit_code, 0)
    t.eq(next_poll.exit_code, 0)
    t.eq(second.stdout, first.stdout)
    t.eq(next_poll.stdout == first.stdout, false)
    t.eq(count_calls(command), 2)
  end,

  test_shared_pr_observe_list_failures_are_not_cached = function()
    author_policy.mock_env(t, nil, {
      configure_trusted_bot_login = h.mock_author_policy_configure,
    })
    local repo = "owner/shared-pr-list"
    local command = core.gh_pr_list_observe_cmd(repo)
    t.mock_command(command, {
      stdout = "",
      stderr = "rate limited",
      exit_code = 1,
    })
    t.mock_command(command, {
      stdout = '[{"number":7,"state":"open","updated_at":"2026-06-03T01:02:03Z"}]\n',
      stderr = "",
      exit_code = 0,
    })

    local first = entity_list_cache.fetch_shared_pr_observe_list(core, repo, {
      poll_key = "2026-06-03T01:02:03Z",
    })
    local second = entity_list_cache.fetch_shared_pr_observe_list(core, repo, {
      poll_key = "2026-06-03T01:02:03Z",
    })

    t.eq(first.exit_code, 1)
    t.eq(second.exit_code, 0)
    t.eq(count_calls(command), 2)
  end,

}
