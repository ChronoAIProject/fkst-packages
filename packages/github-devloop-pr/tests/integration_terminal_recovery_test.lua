local h = require("tests.devloop_helpers")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")

local t = h.t
local core = h.core

local repo = "owner/repo"
local proposal_id = "github-devloop/issue/owner/repo/42"
local pr_number = 7
local branch = "devloop-owner-repo-42-01HY"
local bound_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z/fix/4"

local function event()
  return {
    queue = "devloop_observe_pr",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = pr_number,
      state = "OPEN",
      updated_at = "1970-01-01T00:00:00Z",
      dedup_key = "terminal-refused/observe/head-advanced",
      source = "terminal-refused",
      bound_version = bound_version,
      bound_head_sha = "def456",
      refusal_reason = "head-advanced",
      source_ref = { kind = "external", ref = "owner/repo#pr/7" },
    },
  }
end

local function mock_current_pr()
  local comments = {
    m_builders.pr_origin_marker(proposal_id, "42", branch, bound_version, "dev"),
    core.state_marker(proposal_id, "blocked", bound_version),
  }
  h.mock_bot_env()
  t.mock_command(core.gh_issue_view_claim_cmd(repo, 42), {
    stdout = '{"assignees":[{"login":"fkst-test-bot"}],"author":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = repo,
    number = pr_number,
    comments = comments,
    head = branch,
    head_sha = "feedface",
    base_branch = "dev",
    state = "OPEN",
    head_repo = repo,
    cross_repo = false,
  }, entity_read_mocks.pr_origin_selector, 1)
end

return {
  test_head_advanced_terminal_refusal_reenters_review_without_new_fix_round = function()
    mock_current_pr()

    local result = h.run_department("departments/observe_pr/main.lua", event(), h.opts("terminal-refused-head-advanced"))

    t.eq(result.exit_code, 0)
    local comment = h.find_raise(result.raises, "github-proxy.github_pr_comment_request")
    local label = h.find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.is_true(comment ~= nil)
    t.is_true(label ~= nil)
    local new_version = core.next_review_loop_version(bound_version)
    t.is_true(comment.payload.body:find(core.state_marker(proposal_id, "reviewing", new_version), 1, true) ~= nil)
    t.eq(comment.payload.handoff.kind, "github-devloop.reviewing")
    t.eq(comment.payload.handoff.version, new_version)
    t.eq(label.payload.add_labels[1], "fkst-dev:reviewing")
    t.eq(core.version_fix_round(new_version), core.version_fix_round(bound_version))
  end,
}
