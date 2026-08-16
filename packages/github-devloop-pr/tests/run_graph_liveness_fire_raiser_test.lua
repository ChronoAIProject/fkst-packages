local devloop_base = require("devloop.base")
local t = fkst.test
local core = require("core")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local merge_queue_fixture = require("tests.merge_queue_wip_helpers")
local gh_argv = require("testkit_internal.gh_argv_mock")
gh_argv.install(t, core)

local repo = "owner/repo"

local function mock_env()
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
end

local function mock_empty_board()
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(core.gh_pr_list_observe_cmd(repo), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = 0,
    comments = {},
    labels = {},
    state = "OPEN",
  })
end

local function mock_merge_queue_head_progress()
  local current = merge_queue_fixture.merge_ready()
  local origin_marker = merge_queue_fixture.m_builders.pr_origin_marker(
    current.proposal_id,
    "42",
    "devloop-owner-repo-42-01HY",
    current.version,
    "dev"
  )
  merge_queue_fixture.mock_bot_env()
  merge_queue_fixture.mock_write_env("1")
  merge_queue_fixture.mock_repo_env()
  merge_queue_fixture.mock_queue_list({ 7 })
  merge_queue_fixture.mock_queue_pr(current, "2026-06-03T02:00:00Z")
  merge_queue_fixture.mock_pr_merge(merge_queue_fixture.merge_comments_with_origin(current, origin_marker))
  merge_queue_fixture.mock_write_env("1")
  merge_queue_fixture.mock_claimed_issue_for_event(current, 2)
  merge_queue_fixture.mock_pr_merge(merge_queue_fixture.merge_comments_with_origin(current, origin_marker))
  merge_queue_fixture.mock_pr_merge(merge_queue_fixture.merge_comments_with_origin(current, origin_marker))
  merge_queue_fixture.mock_merging_comment()
  t.mock_command("gh pr merge '7' --repo 'owner/repo' --merge --match-head-commit 'def456'", {
    stdout = "merged\n",
    stderr = "",
    exit_code = 0,
  })
  merge_queue_fixture.mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "def456", "MERGED", "owner/repo", false, "MERGEABLE", "CLEAN", "COMPLETED", "SUCCESS", "2026-06-03T02:03:04Z")
  merge_queue_fixture.mock_issue_close()
  merge_queue_fixture.mock_diff_name_only(7, { "packages/a.lua" })
  merge_queue_fixture.mock_current_base_head("abc124")
  merge_queue_fixture.mock_queue_list({})
end

return {
  test_fire_raiser_liveness_poll_routes_real_tick_to_scan = function()
    mock_env()
    mock_empty_board()
    local trace = t.fire_raiser("liveness_poll")
    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "github-devloop-pr.liveness_poll")
    t.eq(trace.routed_to[1], "github-devloop-pr.liveness_scan")
    t.eq(trace.consumer_result.status, "accepted")
    t.eq(#trace.raised, 0)
    graph.assert_covers(trace, {})
  end,

  test_fire_raiser_merge_queue_poll_merges_current_head = function()
    mock_merge_queue_head_progress()

    local trace = t.fire_raiser("merge_queue_poll")

    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "github-devloop-pr.merge_queue_poll")
    t.eq(trace.routed_to[1], "github-devloop-pr.merge_queue")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    local merged = nil
    for _, raised in ipairs(trace.raised) do
      if raised.queue == "github-proxy.github_pr_comment_request"
        and tostring(raised.payload.body):find("fkst:github-devloop:merged:v1", 1, true) ~= nil then
        merged = raised
      end
    end
    t.is_true(merged ~= nil)
    t.eq(merged.payload.pr_number, 7)
    t.eq(merged.payload.source_ref.ref, "owner/repo#pr/7")
  end,
}
