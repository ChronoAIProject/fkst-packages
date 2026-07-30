local h = require("tests.devloop_core_helpers")
local t = h.t

local base = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function classifier()
  local ok, loaded = pcall(require, "departments.implement.version_mismatch")
  t.eq(ok, true, tostring(loaded))
  return loaded
end

local function assert_decision(actual, status, reason_code, cas_outcome)
  t.eq(actual.status, status)
  t.eq(actual.reason_code, reason_code)
  t.eq(actual.cas_outcome, cas_outcome)
end

return {
  test_older_canonical_same_lineage_is_stale = function()
    assert_decision(
      classifier().classify(base .. "/reimplement/2", base .. "/reimplement/3"),
      "stale",
      "incoming-version-older",
      "skip-stale(incoming version < current marker version)"
    )
  end,

  test_newer_canonical_same_lineage_is_pending = function()
    assert_decision(
      classifier().classify(base .. "/reimplement/3", base .. "/reimplement/2"),
      "pending",
      "source-marker-not-visible",
      "retry-pending(from-state marker not yet visible)"
    )
  end,

  test_different_canonical_lineages_fail_closed = function()
    assert_decision(
      classifier().classify(
        base,
        "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
      ),
      "illegal",
      "incomparable-version-lineage",
      "fail-closed(incomparable-version-lineage)"
    )
  end,

  test_ordering_equal_double_wrapped_lineage_fails_closed = function()
    assert_decision(
      classifier().classify("ready/" .. base, base),
      "illegal",
      "incomparable-version-lineage",
      "fail-closed(incomparable-version-lineage)"
    )
  end,

  test_same_double_wrapped_lineage_fails_closed_before_ordering = function()
    assert_decision(
      classifier().classify("ready/" .. base .. "/reimplement/2", "ready/" .. base .. "/reimplement/3"),
      "illegal",
      "incomparable-version-lineage",
      "fail-closed(incomparable-version-lineage)"
    )
  end,

  test_malformed_same_root_lineages_fail_closed_before_ordering = function()
    local malformed = {
      { base .. "/reimplement/0", base .. "/reimplement/2" },
      { base .. "/reimplement/3/reimplement/2", base .. "/reimplement/4" },
      { base .. "/reimplement/100001", base .. "/reimplement/100000" },
      { base .. "/reimplement/not-a-round/reimplement/2", base .. "/reimplement/not-a-round/reimplement/3" },
    }
    for _, versions in ipairs(malformed) do
      assert_decision(
        classifier().classify(versions[1], versions[2]),
        "illegal",
        "incomparable-version-lineage",
        "fail-closed(incomparable-version-lineage)"
      )
    end
  end,
}
