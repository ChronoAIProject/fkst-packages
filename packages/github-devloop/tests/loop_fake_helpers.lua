local core = require("core")
local run_fake = require("std.testing").run_fake
local gh_fake = require("std.github_fake")
local git_fake = require("std.git_fake")

local M = {}

function M.loop_issue(labels, comments, extra)
  local selected_labels = labels or { "fkst-dev:thinking" }
  local fields = extra or {}
  return {
    number = 42,
    title = fields.title or "Implement decision recorder",
    updated_at = fields.updated_at or "2026-06-03T01:02:03Z",
    state = fields.state or "OPEN",
    labels = selected_labels,
    comments = M.with_default_state_marker(selected_labels, comments),
    assignees = fields.assignees or {},
    author_login = fields.author_login or "fkst-test-bot",
    source_ref = M.source_ref(),
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
  local _result, effects = run_fake(dept, {
    queue = "consensus.consensus_converge",
    payload = payload,
  })
  return {
    exit_code = 0,
    raises = effects.raises,
    model = model,
  }
end

function M.install(helpers)
  M.source_ref = helpers.source_ref
  M.with_default_state_marker = helpers.with_default_state_marker
  helpers.loop_issue = M.loop_issue
  helpers.run_loop_fake = M.run_loop_fake
end

return M
