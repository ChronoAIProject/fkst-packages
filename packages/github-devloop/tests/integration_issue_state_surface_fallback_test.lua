local h = require("tests.devloop_helpers")

local core = h.core
local t = h.t

return {
  test_observe_issue_uses_graphql_state_surface_without_rest = function()
    h.mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {})

    local result = h.run_observe(h.issue(), h.opts("observe-graphql-state-surface"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 3)
    t.eq(h.count_calls(core.gh_issue_view_state_cmd("owner/repo", 42)), 1)
    t.eq(h.count_calls("gh api repos/owner/repo/issues/42"), 0)
    t.eq(h.count_calls("gh api --paginate --slurp"), 0)
  end,

  test_observe_issue_falls_back_to_rest_when_graphql_is_rate_limited = function()
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 42), {
      stdout = "",
      stderr = "GraphQL: secondary rate limit (HTTP 403)",
      exit_code = 1,
    })
    h.mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {})

    local result = h.run_observe(h.issue(), h.opts("observe-rest-state-fallback"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 3)
    t.eq(h.count_calls(core.gh_issue_view_state_cmd("owner/repo", 42)), 1)
    t.eq(h.count_calls("gh api repos/owner/repo/issues/42"), 1)
    t.eq(h.count_calls("gh api --paginate --slurp"), 1)
  end,
}
