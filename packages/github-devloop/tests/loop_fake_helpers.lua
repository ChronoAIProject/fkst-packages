local core = require("core")
local run_fake = require("std.testing").run_fake
local gh_fake = require("std.github_fake")
local git_fake = require("std.git_fake")

local M = {}

function M.loop_issue(labels, comments, extra)
  local selected_labels = labels or { "fkst-dev:thinking" }
  local fields = extra or {}
  local gh_labels = {}
  for _, label in ipairs(selected_labels) do
    table.insert(gh_labels, { name = label })
  end
  local gh_comments = {}
  for _, comment in ipairs(M.with_default_state_marker(selected_labels, comments)) do
    if type(comment) == "table" then
      table.insert(gh_comments, comment)
    else
      table.insert(gh_comments, {
        body = tostring(comment),
        author = { login = fields.comment_author_login or fields.author_login or "fkst-test-bot" },
      })
    end
  end
  local gh_assignees = {}
  for _, assignee in ipairs(fields.assignees or {}) do
    table.insert(gh_assignees, { login = assignee })
  end
  return {
    number = 42,
    title = fields.title or "Implement decision recorder",
    updatedAt = fields.updated_at or "2026-06-03T01:02:03Z",
    state = fields.state or "OPEN",
    labels = gh_labels,
    comments = gh_comments,
    assignees = gh_assignees,
    author = { login = fields.author_login or "fkst-test-bot" },
  }
end

function M.run_loop_fake(payload, issue_value)
  local loop = require("departments.loop.main")
  local model = gh_fake.model({
    issues = {
      ["owner/repo#issue/42"] = issue_value or M.loop_issue(),
    },
  })
  local dept = loop.make_department({
    github = gh_fake.new(model),
    git = git_fake.new(git_fake.model({})),
  })
  dept.model = model
  local result = run_fake(dept, {
    queue = "consensus.consensus_converge",
    payload = payload,
  })
  result.exit_code = result.failure and 1 or 0
  result.model = model
  return result
end

function M.install(helpers)
  M.source_ref = helpers.source_ref
  M.with_default_state_marker = helpers.with_default_state_marker
  helpers.loop_issue = M.loop_issue
  helpers.run_loop_fake = M.run_loop_fake
end

return M
