local h = require("tests.devloop_helpers")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local t = h.t

local M = {}

function M.mock_issue_implement_view_only(labels, comments, times)
  entity_read_mocks.mock_issue_view_raw_selector(t, {},
    "title,body,labels,comments,state,author", {
      stdout = entity_read_mocks.issue_view_stdout({
        labels = labels,
        comments = comments,
      }),
      stderr = "",
      exit_code = 0,
    }, times or 1)
end

function M.trusted_command(id)
  return {
    id = id or "IC_reimplement_1",
    body = "fkst: reimplement",
    author_login = "fkst-test-bot",
    created_at = "2026-06-04T03:00:00Z",
  }
end

return M
