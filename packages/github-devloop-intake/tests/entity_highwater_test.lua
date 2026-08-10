local entity_highwater = require("devloop.entity_highwater")
local h = require("tests.devloop_helpers")

local t = h.t
local consumer = "github-devloop-intake/highwater-unit"
local source_ref = { kind = "external", ref = "owner/repo#issue/3094" }

local function event(updated_at)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      updated_at = updated_at,
      source_ref = source_ref,
    },
  }
end

local function reconcile(updated_at, work)
  return entity_highwater.reconcile({
    consumer = consumer,
    event = event(updated_at),
    work = work,
  })
end

return {
  test_entity_highwater_key_is_readable_and_consumer_local = function()
    t.eq(
      entity_highwater.key(consumer, source_ref),
      "github-devloop-intake/highwater-unit/highwater/owner/repo/issue/3094"
    )
  end,

  test_entity_highwater_skips_only_strictly_older_versions = function()
    local key = entity_highwater.key(consumer, source_ref)
    cache_set(key, "")
    local calls = 0
    local function work(updated_at)
      return function(_, record_authoritative_version)
        calls = calls + 1
        record_authoritative_version(updated_at)
        return "worked"
      end
    end

    local first = reconcile("2026-08-04T00:01:00Z", work("2026-08-04T00:01:00Z"))
    local older = reconcile("2026-08-04T00:00:00Z", work("2026-08-04T00:00:00Z"))
    local equal = reconcile("2026-08-04T00:01:00Z", work("2026-08-04T00:01:00Z"))
    local newer = reconcile("2026-08-04T00:02:00Z", work("2026-08-04T00:02:00Z"))
    local equal_newer = reconcile("2026-08-04T00:02:00Z", work("2026-08-04T00:02:00Z"))

    t.eq(first.outcome, "reconciled")
    t.eq(older.outcome, "skip-superseded-version")
    t.eq(older.skipped, true)
    t.eq(equal.outcome, "reconciled")
    t.eq(newer.outcome, "reconciled")
    t.eq(equal_newer.outcome, "reconciled")
    t.eq(calls, 4)
    t.eq(cache_get(key), "2026-08-04T00:02:00Z")
  end,

  test_entity_highwater_commits_the_authoritative_version_reported_by_work = function()
    local key = entity_highwater.key(consumer, source_ref)
    cache_set(key, "")
    local calls = 0
    local current = "2026-08-04T00:07:11Z"

    local first = reconcile("2026-08-04T00:00:00Z", function(_, record_authoritative_version)
      calls = calls + 1
      record_authoritative_version(current)
    end)
    local superseded = reconcile("2026-08-04T00:07:10Z", function()
      calls = calls + 1
    end)
    local non_regressing = reconcile(current, function(_, record_authoritative_version)
      calls = calls + 1
      record_authoritative_version("2026-08-04T00:00:00Z")
    end)

    t.eq(first.outcome, "reconciled")
    t.eq(first.reconciled_updated_at, current)
    t.eq(superseded.outcome, "skip-superseded-version")
    t.eq(non_regressing.reconciled_updated_at, current)
    t.eq(calls, 2)
    t.eq(cache_get(key), current)
  end,

  test_entity_highwater_fails_open_and_advances_only_after_success = function()
    local key = entity_highwater.key(consumer, source_ref)
    cache_set(key, "")
    local invalid_calls = 0

    local invalid = reconcile("not-a-timestamp", function()
      invalid_calls = invalid_calls + 1
    end)
    t.eq(invalid.outcome, "reconciled")
    t.eq(invalid_calls, 1)
    t.eq(cache_get(key), "")

    reconcile("2026-08-04T00:02:00Z", function(_, record_authoritative_version)
      record_authoritative_version("not-a-timestamp")
    end)
    t.eq(cache_get(key), "")

    local ok = pcall(function()
      reconcile("2026-08-04T00:02:00Z", function(_, record_authoritative_version)
        record_authoritative_version("2026-08-04T00:03:00Z")
        error("work failed")
      end)
    end)
    t.eq(ok, false)
    t.eq(cache_get(key), "")
  end,

  test_entity_highwater_runs_work_before_its_short_cache_commit_lock = function()
    local key = entity_highwater.key(consumer, source_ref)
    cache_set(key, "")
    local previous_with_lock = with_lock
    local events = {}

    with_lock = function(selected_key, fn)
      events[#events + 1] = "lock-enter:" .. tostring(selected_key)
      local result = fn()
      events[#events + 1] = "lock-exit"
      return result
    end
    local ok, result = pcall(reconcile, "2026-08-04T00:04:00Z", function(_, record_authoritative_version)
      events[#events + 1] = "source-read"
      record_authoritative_version("2026-08-04T00:04:00Z")
      events[#events + 1] = "effect-plan"
    end)
    with_lock = previous_with_lock

    if not ok then error(result, 0) end
    t.eq(events[1], "source-read")
    t.eq(events[2], "effect-plan")
    t.eq(events[3], "lock-enter:" .. key)
    t.eq(events[4], "lock-exit")
    t.eq(cache_get(key), "2026-08-04T00:04:00Z")
  end,
}
