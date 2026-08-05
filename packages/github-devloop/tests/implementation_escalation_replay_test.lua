local escalation = require("devloop.implementation_escalation")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local replay_fields = require("devloop.replay_fields")
local replayer = require("devloop.replayer")
local testing = require("testkit_internal.testing")

local t = h.t
local core = h.core
local repo = "owner/repo"
local issue_number = 42
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "ready/github-devloop/issue/owner/repo/42/intake/123"
local branch = "devloop-owner-repo-42-123"
local checkpoint_head = "1111111111111111111111111111111111111111"
local base_head = "2222222222222222222222222222222222222222"

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-08-05T01:00:00Z",
  }
end

local function evidence()
  return {
    policy_id = "adjacent-wall-clock-exhaustion-stationary-head-v1",
    previous_attempt = 1,
    attempt = 2,
    head_sha = checkpoint_head,
  }
end

local function escalation_payload()
  return escalation.build_payload({
    proposal_id = proposal_id,
    version = version,
    branch = branch,
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
  }, evidence())
end

local function base_comments()
  return {
    trusted_comment(core.state_marker(proposal_id, "implementation-escalating", version)),
    trusted_comment(m_builders.implement_checkpoint_marker(
      proposal_id,
      version,
      branch,
      checkpoint_head,
      "dev",
      base_head,
      2,
      "wall-clock-exhausted"
    )),
    trusted_comment(escalation.escalation_marker(proposal_id, version, evidence())),
  }
end

local function child_markers(payload, child_number)
  local request = escalation.build_child_issue_request(repo, issue_number, payload, {
    title = "Extract parser",
    body = "Implement the parser independently.",
  }, 1)
  return {
    created = '<!-- fkst:github-proxy:issue-created:v1 dedup="'
      .. request.dedup_key .. '" issue="' .. tostring(child_number) .. '" -->',
    linked = '<!-- fkst:github-proxy:blocked-by:v1 dedup="'
      .. request.post_create_blocked_by.dedup_key
      .. '" blocked="42" blocking="' .. tostring(child_number) .. '" -->',
  }
end

local function with_comment(comments, body)
  local copied = {}
  for _, comment in ipairs(comments) do
    table.insert(copied, comment)
  end
  table.insert(copied, trusted_comment(body))
  return copied
end

local function issue()
  return {
    repo = repo,
    number = issue_number,
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
  }
end

local function run_replay(comments, dependency_gate)
  local state = {
    state = "implementation-escalating",
    version = version,
    proposal_id = proposal_id,
  }
  local current = {
    labels = { "fkst-dev:enabled", "fkst-dev:implementing" },
    comments = comments,
  }
  local row = replay_fields.restart_transition_row(
    core.restart_transition_table(),
    "implementation-escalating"
  )
  return testing.run_fake({
    pipeline = function()
      return replayer.replay_from_table(core, "observe_issue", issue(), state, row, {
        proposal_id = proposal_id,
        current = current,
        snapshot = { comments = comments, prs = {}, state = state },
        dependency_gate = dependency_gate,
      })
    end,
  }, {
    queue = "github-proxy.github_entity_changed",
    payload = issue(),
  })
end

local function raises_for(result, queue)
  local matches = {}
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue then
      table.insert(matches, raised)
    end
  end
  return matches
end

local function comments_with_plan()
  local payload = escalation_payload()
  return payload, with_comment(base_comments(), escalation.decomposition_marker(payload, 1))
end

return {
  test_missing_decomposition_plan_reissues_dedicated_supervisor = function()
    local result = run_replay(base_comments())
    local raised = raises_for(result, "github-devloop-decompose.devloop_implementation_decompose")

    t.eq(#raised, 1)
    t.eq(escalation.is_supported_payload(raised[1].payload), true)
    t.eq(#raises_for(result, "github-proxy.github_issue_comment_request"), 0)
  end,

  test_partial_child_linkage_reissues_dedicated_supervisor = function()
    local payload, comments = comments_with_plan()
    local markers = child_markers(payload, 101)
    comments = with_comment(comments, markers.created)

    local result = run_replay(comments)

    t.eq(#raises_for(result, "github-devloop-decompose.devloop_implementation_decompose"), 1)
    t.eq(#raises_for(result, "github-proxy.github_issue_comment_request"), 0)
  end,

  test_complete_child_linkage_enters_dependency_wait_through_comment_handoff = function()
    local payload, comments = comments_with_plan()
    local markers = child_markers(payload, 101)
    comments = with_comment(comments, markers.created .. "\n" .. markers.linked)

    local result = run_replay(comments, {
      ok = false,
      kind = "waiting",
      reason = "waiting-on-dependency",
      unmet = { 101 },
    })
    local raised = raises_for(result, "github-proxy.github_issue_comment_request")

    t.eq(#raises_for(result, "github-devloop-decompose.devloop_implementation_decompose"), 0)
    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('state="dependency_wait"', 1, true) ~= nil)
    t.eq(raised[1].payload.handoff.kind, "github-devloop.ready-split-label")
  end,

  test_complete_satisfied_child_linkage_enters_ready_through_comment_handoff = function()
    local payload, comments = comments_with_plan()
    local markers = child_markers(payload, 101)
    comments = with_comment(comments, markers.created .. "\n" .. markers.linked)

    local result = run_replay(comments, {
      ok = true,
      kind = "satisfied",
      reason = "dependencies-satisfied",
      unmet = {},
    })
    local raised = raises_for(result, "github-proxy.github_issue_comment_request")

    t.eq(#raises_for(result, "github-devloop-decompose.devloop_implementation_decompose"), 0)
    t.eq(#raised, 1)
    t.is_true(raised[1].payload.body:find('state="ready"', 1, true) ~= nil)
    t.eq(raised[1].payload.handoff.kind, "github-devloop.ready")
  end,
}
