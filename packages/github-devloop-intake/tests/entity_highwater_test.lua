local entity_highwater = require("devloop.entity_highwater")
local h = require("tests.devloop_helpers")

local t = h.t
local consumer = "github-devloop-intake/highwater-unit"
local source_ref = { kind = "external", ref = "owner/repo#issue/3094" }
local lock_key = "github-devloop/transition/owner/repo/issue/3094"

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
    lock_key = lock_key,
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
    local function work()
      calls = calls + 1
      return "worked"
    end

    local first = reconcile("2026-08-04T00:01:00Z", work)
    local older = reconcile("2026-08-04T00:00:00Z", work)
    local equal = reconcile("2026-08-04T00:01:00Z", work)
    local newer = reconcile("2026-08-04T00:02:00Z", work)
    local equal_newer = reconcile("2026-08-04T00:02:00Z", work)

    t.eq(first.outcome, "reconciled")
    t.eq(older.outcome, "skip-superseded-version")
    t.eq(older.skipped, true)
    t.eq(equal.outcome, "reconciled")
    t.eq(newer.outcome, "reconciled")
    t.eq(equal_newer.outcome, "reconciled")
    t.eq(calls, 4)
    t.eq(cache_get(key), "2026-08-04T00:02:00Z")
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

    local ok = pcall(function()
      reconcile("2026-08-04T00:02:00Z", function()
        error("work failed")
      end)
    end)
    t.eq(ok, false)
    t.eq(cache_get(key), "")
  end,
}
