local entity_list_cache = require("devloop.entity_list_cache")
local h = require("tests.proxy_integration_helpers")
local author_policy = require("testkit_internal.github_author_policy")
local testing = require("testkit_internal.testing")
local github_poll = require("departments.github_poll.main")
local t = h.t

return {
  test_github_poll_records_the_current_authorization_epoch = function()
    local event = {
      queue = "github_poll_tick",
      ts = "2026-07-30T01:02:03Z",
      payload = {},
    }
    h.mock_repo_env()
    h.mock_poll_label_prefix_env("adapter-")
    author_policy.mock_env(t, h.opts("poll-authorization-epoch"))
    h.mock_poll()
    cache_set(entity_list_cache.poll_epoch_cache_key("owner/x"), "")

    local recorded_repo = nil
    local recorded_epoch = nil
    local allocated_epoch = nil
    local original_record = entity_list_cache.record_poll_epoch
    entity_list_cache.record_poll_epoch = function(repo, epoch)
      recorded_repo = repo
      recorded_epoch = epoch
      local recorded, allocated = original_record(repo, epoch)
      allocated_epoch = allocated
      return recorded, allocated
    end
    local ok, result = pcall(testing.run_fake, github_poll, event)
    entity_list_cache.record_poll_epoch = original_record
    if not ok then
      error(result, 0)
    end

    t.eq(recorded_repo, "owner/x")
    t.eq(recorded_epoch, event.ts)
    t.eq(result.raises[1].payload.poll_token, allocated_epoch)
  end,

  test_github_poll_equal_timestamp_replay_emits_a_distinct_allocated_epoch = function()
    local event = {
      queue = "github_poll_tick",
      ts = "2026-07-30T01:02:03Z",
      payload = {},
    }
    cache_set(entity_list_cache.poll_epoch_cache_key("owner/x"), "")

    h.mock_repo_env()
    h.mock_poll_label_prefix_env("adapter-")
    author_policy.mock_env(t, h.opts("poll-equal-epoch-first"))
    h.mock_poll()
    local first = testing.run_fake(github_poll, event)

    h.mock_repo_env()
    h.mock_poll_label_prefix_env("adapter-")
    author_policy.mock_env(t, h.opts("poll-equal-epoch-replay"))
    h.mock_poll()
    local replayed = testing.run_fake(github_poll, event)

    t.is_true(#first.raises > 0)
    t.is_true(#replayed.raises > 0)
    local first_epoch = first.raises[1].payload.poll_token
    local replayed_epoch = replayed.raises[1].payload.poll_token
    t.is_true(first_epoch ~= replayed_epoch, "fresh equal-timestamp polls receive distinct execution epochs")
    t.is_true(entity_list_cache.poll_epoch_is_current("owner/x", replayed_epoch))
  end,

  test_github_poll_suppresses_emissions_from_an_older_replayed_tick = function()
    local older = "2026-07-30T01:02:03Z"
    local newer = "2026-07-30T01:02:04Z"
    cache_set(entity_list_cache.poll_epoch_cache_key("owner/x"), "")
    entity_list_cache.record_poll_epoch("owner/x", older)
    local _, newer_epoch = entity_list_cache.record_poll_epoch("owner/x", newer)
    h.mock_repo_env()
    h.mock_poll_label_prefix_env("adapter-")
    author_policy.mock_env(t, h.opts("poll-authorization-epoch-replay"))
    h.mock_poll()

    local result = testing.run_fake(github_poll, {
      queue = "github_poll_tick",
      ts = older,
      payload = {},
    })

    t.eq(#result.raises, 0)
    t.is_true(entity_list_cache.poll_epoch_is_current("owner/x", newer_epoch))
  end,

  test_deferred_cold_observation_is_suppressed_after_entity_cache_advances = function()
    local event = {
      queue = "github_poll_tick",
      ts = "2026-07-30T01:02:05Z",
      payload = {},
    }
    cache_set(entity_list_cache.poll_epoch_cache_key("owner/x"), "")
    h.mock_repo_env()
    h.mock_poll_label_prefix_env("adapter-")
    h.mock_proxy_replay_budget_env("1")
    author_policy.mock_env(t, h.opts("poll-deferred-stale-snapshot"))
    h.mock_issue_list(h.poll_issue_list_from({
      h.poll_issue_json(9142, "2026-06-03T01:02:00Z"),
      h.poll_issue_json(9143, "2026-06-03T01:03:00Z"),
    }))
    h.mock_pr_list("[]\n")

    local original_with_current = entity_list_cache.with_current_poll_epoch
    entity_list_cache.with_current_poll_epoch = function(repo, epoch, fn)
      cache_set(h.core.entity_cache_key("owner/x", "issue", 9143), "2026-06-03T01:04:00Z")
      return original_with_current(repo, epoch, fn)
    end
    local ok, result = pcall(testing.run_fake, github_poll, event)
    entity_list_cache.with_current_poll_epoch = original_with_current
    if not ok then
      error(result, 0)
    end

    t.eq(#h.changed_raises(result.raises), 1)
    t.eq(h.changed_raises(result.raises)[1].payload.number, 9142)
    t.eq(#h.observed_issue_raises(result.raises), 0)
  end,
}
