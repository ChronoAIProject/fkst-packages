local devloop_base = require("devloop.base")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local graph = require("testkit.graph")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")

local t = h.t
local core = h.core

local repo = "owner/repo"
local issue_number = 42
local pr_number = 2914
local observed_updated_at = "2026-08-05T01:02:03Z"

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-07-30T01:02:03Z",
  }
end

local function mock_runtime_config()
  for _ = 1, 8 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = repo,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function fixture()
  local event = h.fixing()
  local _, _, review_version = devloop_base.parse_pr_review_proposal_id(
    event.review_proposal_id)
  event.pr_number = pr_number
  event.review_proposal_id = devloop_base.pr_review_proposal_id(
    repo, pr_number, review_version, event.reviewed_head_sha)
  event.review_dedup_key = devloop_base.pr_review_consensus_dedup_key(
    event.review_proposal_id)
  local branch = devloop_base.implement_branch(repo, tostring(issue_number), event.version)
  local foreign_review_proposal = devloop_base.pr_review_proposal_id(
    repo, pr_number, event.version, "feedface")
  local mismatched_review_dedup =
    devloop_base.pr_review_consensus_dedup_key(foreign_review_proposal)
  local comments = {
    trusted_comment(m_builders.pr_origin_marker(
      event.proposal_id, tostring(issue_number), branch, event.version, "dev")),
    trusted_comment(core.state_marker(event.proposal_id, "fixing", event.version)),
    trusted_comment(m_builders.merge_gate_marker(
      event.proposal_id,
      pr_number,
      event.version,
      event.review_proposal_id,
      mismatched_review_dedup,
      event.reviewed_head_sha,
      nil,
      "mergeable-conflicting"
    )),
  }
  return event, branch, comments
end

local function mock_replay_entry(event, branch, comments)
  local fields = {
    repo = repo,
    number = pr_number,
    head = branch,
    head_sha = event.reviewed_head_sha,
    base_branch = "dev",
    comments = comments,
    labels = { "fkst-dev:fixing" },
    state = "OPEN",
    updated_at = observed_updated_at,
  }
  entity_read_mocks.mock_pr_read_forms(t, fields)
  entity_read_mocks.mock_pr_view_selector(
    t, fields, entity_read_mocks.pr_origin_selector)
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "assignees,author,labels", 4)
end

local function initial_event()
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "pr",
      repo = repo,
      number = pr_number,
      title = "Mismatched fix feedback recovery",
      updated_at = observed_updated_at,
      dedup_key = repo .. "#pr/" .. tostring(pr_number) .. "@" .. observed_updated_at,
      source_ref = entity_lib.pr_source_ref(repo, pr_number),
    },
    source_ref = {
      kind = "external",
      reference = repo .. "#pr/" .. tostring(pr_number),
    },
  }
end

return {
  test_run_graph_mismatched_fix_feedback_reenters_reviewing_for_current_head = function()
    local event, branch, comments = fixture()
    mock_runtime_config()
    mock_replay_entry(event, branch, comments)

    local trace = graph.require_quiescent(
      graph.run(initial_event(), { max_steps = 12 }))
    graph.assert_covers(trace, {
      "github-proxy.github_entity_changed -> github-devloop-pr.observe_pr",
    })
    t.eq(trace.final.dead_letters, 0)
    local observed = graph.require_delivery(trace, {
      queue = "github-proxy.github_entity_changed",
      consumer = "github-devloop-pr.observe_pr",
    })
    t.eq(observed.exit_code, 0, tostring(observed.error))

    local reviewing = graph.require_raise(
      trace, "github-proxy.github_pr_comment_request", function(raised)
        return raised.payload.handoff ~= nil
          and raised.payload.handoff.kind == "github-devloop.reviewing"
      end)
    t.eq(reviewing.payload.handoff.version, core.next_fix_version(event.version))
    t.is_true(reviewing.payload.body:find(
      core.state_marker(event.proposal_id, "reviewing", core.next_fix_version(event.version)),
      1,
      true
    ) ~= nil)
    t.is_true(reviewing.payload.body:find(
      "github-devloop rejected invalid fix feedback and re-entered review",
      1,
      true
    ) ~= nil)
    t.is_true(reviewing.payload.body:find(event.reviewed_head_sha, 1, true) ~= nil)
  end,
}
