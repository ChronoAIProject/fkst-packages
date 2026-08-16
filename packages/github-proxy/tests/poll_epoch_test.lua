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

  test_github_poll_discards_an_item_when_a_newer_batch_writes_it_first = function()
    local repo = "owner/x"
    local entity_number = 9701
    local observed_issue_number = 9702
    local older_poll = "2026-08-10T01:02:03Z"
    local newer_poll = "2026-08-10T01:02:04Z"
    local older_updated_at = "2026-08-10T01:01:03Z"
    local newer_updated_at = "2026-08-10T01:01:04Z"
    local observed_updated_at = "2026-08-10T01:00:00Z"
    local entity_key = h.core.entity_cache_key(repo, "pr", entity_number)
    local observed_issue_key = h.core.entity_cache_key(repo, "issue", observed_issue_number)
    local issues = h.poll_issue_list_from({
      h.poll_issue_json(observed_issue_number, observed_updated_at),
    })
    local older_prs = h.poll_pr_list_from({
      h.poll_pr_json(entity_number, older_updated_at, "OPEN"),
    })
    local newer_prs = h.poll_pr_list_from({
      h.poll_pr_json(entity_number, newer_updated_at, "OPEN"),
    })
    cache_set(entity_list_cache.poll_epoch_cache_key(repo), "")
    cache_set(entity_key, "")
    cache_set(observed_issue_key, observed_updated_at)

    author_policy.mock_env(t, h.opts("poll-item-epoch-a"))
    h.mock_poll(issues, older_prs)

    local original_guard = entity_list_cache.run_if_current_poll_epoch
    local interleaved = false
    local newer_result = nil
    entity_list_cache.run_if_current_poll_epoch = function(actual_repo, poll_epoch, fn)
      if interleaved then
        return original_guard(actual_repo, poll_epoch, fn)
      end
      t.eq(actual_repo, repo)
      t.is_true(entity_list_cache.poll_epoch_is_current(actual_repo, poll_epoch))
      interleaved = true

      author_policy.mock_env(t, h.opts("poll-item-epoch-b"))
      h.mock_poll(issues, newer_prs)
      newer_result = testing.run_fake(github_poll, {
        queue = "github_poll_tick",
        ts = newer_poll,
        payload = {},
      })
      t.eq(cache_get(entity_key), newer_updated_at)
      return true, fn()
    end

    local ok, older_result = pcall(testing.run_fake, github_poll, {
      queue = "github_poll_tick",
      ts = older_poll,
      payload = {},
    })
    entity_list_cache.run_if_current_poll_epoch = original_guard
    if not ok then
      error(older_result, 0)
    end

    t.is_true(interleaved)
    local newer_changes = h.changed_raises(newer_result.raises)
    t.eq(#newer_changes, 1)
    t.eq(newer_changes[1].payload.updated_at, newer_updated_at)
    t.eq(#h.observed_issue_raises(newer_result.raises), 1)
    t.is_true(entity_list_cache.poll_epoch_is_current(repo, newer_changes[1].payload.poll_token))
    t.eq(#older_result.raises, 0)
    t.eq(cache_get(entity_key), newer_updated_at)
    t.eq(cache_get(observed_issue_key), observed_updated_at)
  end,
}
