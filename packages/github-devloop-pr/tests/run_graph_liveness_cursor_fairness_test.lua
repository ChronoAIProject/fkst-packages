local devloop_base = require("devloop.base")
local h = require("tests.devloop_helpers")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")

local t = h.t
local core = h.core

local repo = "owner/repo"
local low_pr_number = 3
local target_pr_number = 7

local function trusted_comment(body)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = "2026-06-03T01:00:00Z",
  }
end

local function mock_env()
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

local function mock_under_cap_pr_list()
  local stdout = '[{"number":3,"state":"open","updated_at":"2026-06-04T01:02:03Z"},'
    .. '{"number":7,"state":"open","updated_at":"2026-06-04T01:02:04Z"}]\n'
  for _ = 1, 2 do
    t.mock_command(core.gh_pr_list_observe_cmd(repo), {
      stdout = stdout,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh api 'repos/owner/repo/pulls/3'", {
      stdout = "",
      stderr = "command timed out",
      exit_code = 124,
    })
  end
end

local function mock_target_fixing_pr()
  local event = h.fixing()
  local comments = {
    trusted_comment(m_builders.pr_origin_marker(
      event.proposal_id,
      "42",
      "devloop-owner-repo-42-01HY",
      event.version,
      "dev"
    )),
    trusted_comment(core.state_marker(event.proposal_id, "fixing", event.version)),
    trusted_comment(m_builders.review_result_marker(
      event.review_proposal_id,
      event.proposal_id,
      "reject",
      event.review_dedup_key,
      1,
      "missing regression guard"
    )),
    trusted_comment(m_builders.merge_gate_marker(
      event.proposal_id,
      target_pr_number,
      event.version,
      event.review_proposal_id,
      event.review_dedup_key,
      event.reviewed_head_sha,
      nil,
      "missing regression guard"
    )),
  }

  entity_read_mocks.mock_pr_read_forms(t, {
    repo = repo,
    number = target_pr_number,
    head = "devloop-owner-repo-42-01HY",
    head_sha = event.reviewed_head_sha,
    base_branch = "dev",
    state = "OPEN",
    updated_at = "2026-06-04T01:02:04Z",
    comments = comments,
    labels = {},
    register_all_views = true,
    times = 8,
  })
  entity_read_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = 42,
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
  }, "assignees,author", 8)
end

local function liveness_tick(ts)
  return {
    queue = "github-devloop-pr.devloop_liveness_tick",
    payload = {
      schema = "github-devloop.tick.v1",
      source_ref = { kind = "cron", ref = "github-devloop-pr/liveness-poll" },
    },
    ts = ts,
    source_ref = { kind = "cron", reference = "github-devloop-pr/liveness-poll" },
  }
end

local function with_no_codex_runs(fn)
  local original = fkst.codex_runs
  fkst.codex_runs = function()
    return { running = {}, recent = {} }
  end
  local ok, result = pcall(fn)
  fkst.codex_runs = original
  if not ok then
    error(result, 0)
  end
  return result
end

return {
  test_under_cap_deadline_scan_resumes_later_fixing_pr_on_next_tick = function()
    mock_env()
    mock_under_cap_pr_list()
    mock_target_fixing_pr()

    with_no_codex_runs(function()
      local first = graph.run(liveness_tick(101), { max_steps = 1 })
      graph.assert_covers(first, {
        "github-devloop-pr.devloop_liveness_tick -> github-devloop-pr.liveness_scan",
      })
      t.eq(graph.find_raise(first, "github-proxy.github_pr_comment_request"), nil)

      local second = graph.require_quiescent(graph.run(liveness_tick(102), { max_steps = 3 }))
      graph.assert_covers(second, {
        "github-devloop-pr.devloop_liveness_tick -> github-devloop-pr.liveness_scan",
      })
      local timeout_attempt = graph.require_raise(second, "github-proxy.github_pr_comment_request", function(raised)
        return tonumber(raised.payload.pr_number) == target_pr_number
          and tostring(raised.payload.body or ""):find("fkst:github-devloop:timeout-attempt", 1, true) ~= nil
      end)
      t.eq(tonumber(timeout_attempt.payload.pr_number), target_pr_number)
      t.eq(graph.find_raise(second, "devloop_timeout_reconcile"), nil)
      t.eq(graph.find_raise(second, "github-devloop-pr.devloop_timeout_reconcile"), nil)
    end)
  end,
}
