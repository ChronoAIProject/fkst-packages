local h = require("tests.devloop_helpers")
local t = h.t

return {
  test_implement_stops_before_add_when_worktree_cleanup_fails = function()
    local event = h.ready()
    h.mock_issue_implement({ "fkst-dev:ready" })
    h.mock_fresh_implement_worktree({
      force_clean = {
        remove_result = {
          stdout = "",
          stderr = "git metadata is busy",
          exit_code = 128,
        },
        directory_result = {
          stdout = "",
          stderr = "permission denied",
          exit_code = 1,
        },
      },
    })

    local actual = h.run_implement(event, h.opts("implement-worktree-cleanup-failure"))

    t.eq(actual.exit_code, 1)
    t.is_true(tostring(actual.error):find("worktree-cleanup-failed", 1, true) ~= nil)
    t.is_true(tostring(actual.error):find("directory-remove", 1, true) ~= nil)
    t.is_true(tostring(actual.error):find("permission denied", 1, true) ~= nil)
    t.is_true(tostring(actual.error):find("git metadata is busy", 1, true) ~= nil)
    t.eq(h.count_calls("git worktree add"), 0)
  end,
}
