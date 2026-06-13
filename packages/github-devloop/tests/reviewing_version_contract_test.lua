local h = require("tests.devloop_core_helpers")
local core = h.core
local t = h.t

return {
  test_reviewing_version_transition_status_canonicalizes_transition_suffixes = function()
    local review_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-05T01-02-03Z"

    t.eq(core.reviewing_version_transition_status({
      state = "reviewing",
      version = review_version,
    }, review_version .. "/review-loop/3"), "apply")
    t.eq(core.reviewing_version_transition_status({
      state = "pr-open",
      version = review_version,
    }, review_version .. "/review-loop/3"), "pending")
    t.eq(core.reviewing_version_transition_status({
      state = "merge-ready",
      version = review_version,
    }, review_version .. "/review-loop/3"), "stale")
    t.eq(core.reviewing_version_transition_status({
      state = "reviewing",
      version = review_version .. "-other",
    }, review_version .. "/review-loop/3"), "version-mismatch")
  end,
}
