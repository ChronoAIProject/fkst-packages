local conv_attempts = require("devloop.convergence.attempts")
local conv_reconcile = require("devloop.convergence.reconcile")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")
local replay_fields = require("devloop.replay_fields")
local testing = require("testkit_internal.testing")
local reconcile_department = require("departments.reconcile.main")

local t = h.t
local core = h.core
local REPO = "owner/repo"
local ISSUE_NUMBER = 42
local PR_NUMBER = 7
local NOW_SECONDS = 1784048400
local CREATED_AT = "2026-06-03T01:00:00Z"

local function timeout_event(surface)
  local seed = h.fix_reconcile()
  local source_ref = surface == "issue"
    and entity_lib.issue_source_ref(REPO, ISSUE_NUMBER)
    or entity_lib.pr_source_ref(REPO, PR_NUMBER)
  local state_version = seed.issue_version .. "/timeout/blocked/3"
  local row = replay_fields.restart_transition_row(core.restart_transition_table(), "blocked")
  return {
    queue = "devloop_timeout_reconcile",
    payload = conv_reconcile.build_devloop_timeout_reconcile_payload(
      row,
      { state = "blocked", version = state_version },
      seed.proposal_id,
      source_ref,
      3
    ),
    now_seconds = NOW_SECONDS,
  }
end

local function comments_for(event, marker_visible)
  local comments = {
    {
      body = core.state_marker(event.payload.proposal_id, "blocked", event.payload.issue_version),
      author_login = "fkst-test-bot",
      created_at = CREATED_AT,
    },
  }
  if marker_visible then
    table.insert(comments, {
      body = conv_attempts.decompose_exhausted_marker(
        event.payload.proposal_id,
        event.payload.issue_version,
        event.payload.round,
        event.payload.source_ref
      ),
      author_login = "fkst-test-bot",
      created_at = CREATED_AT,
    })
  end
  return comments
end

local function prepare_fixture(surface, comments)
  h.mock_bot_env()
  h.mock_default_issue_claim(REPO, ISSUE_NUMBER)
  if surface == "issue" then
    entity_read_mocks.mock_issue_read_forms(t, {
      repo = REPO,
      number = ISSUE_NUMBER,
      comments = comments,
      labels = {},
      assignees = { "fkst-test-bot" },
      author_login = "fkst-test-bot",
      register_all_views = true,
      times = 1,
    })
    return
  end
  entity_read_mocks.mock_pr_view_selector(t, {
    repo = REPO,
    number = PR_NUMBER,
    comments = comments,
    head = "devloop-owner-repo-42-01HY",
    head_sha = "def456",
    state = "OPEN",
    base_branch = "dev",
    labels = {},
  }, entity_read_mocks.pr_origin_selector, 1)
end

local function run_case(surface, marker_visible)
  local event = timeout_event(surface)
  prepare_fixture(surface, comments_for(event, marker_visible))
  local original_now = now
  now = function() return NOW_SECONDS end
  local ok, result = pcall(testing.run_fake, reconcile_department, event)
  now = original_now
  if not ok then error(result, 0) end
  return result
end

return {
  test_timeout_reconcile_blocked_payload_family_is_runtime_classified = function()
    local pr = run_case("pr", false)
    t.eq(#pr.raises, 1, "PR decompose exhaustion emits one comment")
    t.eq(pr.raises[1].queue, "github-proxy.github_pr_comment_request")

    local issue = run_case("issue", false)
    t.eq(#issue.raises, 1, "issue decompose exhaustion emits one comment")
    t.eq(issue.raises[1].queue, "github-proxy.github_issue_comment_request")

    local visible = run_case("pr", true)
    t.eq(#visible.raises, 0, "visible decompose exhaustion marker is idempotent")
  end,
}
