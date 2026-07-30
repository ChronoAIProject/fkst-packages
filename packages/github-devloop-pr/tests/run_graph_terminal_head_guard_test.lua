local devloop_base = require("devloop.base")
local terminal_guard = require("devloop.terminal_guard")
local h = require("tests.devloop_helpers")
local graph = require("testkit.graph")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")

local t = h.t
local core = h.core
local repo = "owner/repo"
local pr_number = 7
local proposal_id = "github-devloop/issue/owner/repo/42"
local branch = "devloop-owner-repo-42-01HY"

local function reconcile_request()
  local reconcile = h.fix_reconcile()
  return core.build_fix_reconcile_comment_request(
    repo,
    42,
    reconcile,
    "drop",
    "fix-loop-max-rounds",
    "merging"
  ), reconcile
end

local function refusal(origin)
  local request, reconcile = reconcile_request()
  return terminal_guard.refusal_payload(
    request.terminal_guard,
    repo,
    pr_number,
    {
      state = "OPEN",
      head_sha = "feedface",
      head_repository = repo,
      is_cross_repository = false,
    },
    { state = "merging", version = reconcile.issue_version },
    "head-advanced",
    reconcile.source_ref,
    origin,
    request.dedup_key
  )
end

local function mock_env()
  for _ = 1, 8 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = "1",
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
  end
end

local function mock_observer_after_head_advance(bound_version, closed)
  local reviewing_version = core.next_review_loop_version(bound_version)
  local review_proposal_id = devloop_base.pr_review_proposal_id(repo, pr_number, reviewing_version, "feedface")
  local review_dedup_key = devloop_base.pr_review_consensus_dedup_key(review_proposal_id)
  local comments = {
    m_builders.pr_origin_marker(proposal_id, "42", branch, bound_version, "dev"),
  }
  if closed then
    table.insert(comments, core.state_marker(proposal_id, "blocked", bound_version))
  else
    table.insert(comments, core.state_marker(proposal_id, "reviewing", reviewing_version))
    table.insert(comments, m_builders.review_result_marker(review_proposal_id, proposal_id, "approve", review_dedup_key))
  end
  h.mock_default_issue_claim(repo, 42)
  local fields = {
    repo = repo,
    number = pr_number,
    comments = comments,
    head = branch,
    head_sha = "feedface",
    base_branch = "dev",
    state = closed and "CLOSED" or "OPEN",
    head_repo = repo,
    cross_repo = false,
    labels = { closed and "fkst-dev:blocked" or "fkst-dev:reviewing" },
    mergeable = "MERGEABLE",
    merge_state = "CLEAN",
  }
  entity_read_mocks.mock_pr_read_forms(t, fields)
  entity_read_mocks.mock_pr_view_selector(t, fields, entity_read_mocks.pr_origin_selector, 1)
end

local function initial(queue, payload)
  return {
    queue = queue,
    payload = payload,
    source_ref = {
      kind = "external",
      reference = "owner/repo#pr/7",
    },
  }
end

return {
  test_run_graph_terminal_writer_refuses_advanced_head_and_redrives_observer = function()
    local request, reconcile = reconcile_request()
    mock_env()
    local source_marker = core.state_marker(proposal_id, "merging", reconcile.issue_version)
    for _, command in ipairs({
      "gh api --paginate --slurp repos/owner/repo/issues/7/comments?per_page=100",
      "gh api --paginate --slurp 'repos/owner/repo/issues/7/comments?per_page=100'",
    }) do
      t.mock_command(command, {
        stdout = '[[{"id":1,"body":"' .. h.json_string(source_marker) .. '","user":{"login":"fkst-test-bot"}}]]\n',
        stderr = "",
        exit_code = 0,
      })
    end
    for _, command in ipairs({
      "gh api repos/owner/repo/pulls/7",
      "gh api 'repos/owner/repo/pulls/7'",
    }) do
      t.mock_command(command, {
        stdout = '{"number":7,"state":"open","head":{"ref":"' .. branch .. '","sha":"feedface","repo":{"full_name":"owner/repo","owner":{"login":"owner"}}},"base":{"ref":"dev","sha":"abc123","repo":{"full_name":"owner/repo","owner":{"login":"owner"}}}}\n',
        stderr = "",
        exit_code = 0,
      })
    end
    mock_observer_after_head_advance(reconcile.issue_version)

    local trace = graph.require_quiescent(graph.run(
      initial("github-proxy.github_pr_comment_request", request),
      { max_steps = 3 }
    ))
    graph.assert_covers(trace, {
      "github-proxy.github_pr_comment_request -> github-proxy.github_pr_comment",
      "github-proxy.github_comment_refused -> github-devloop-pr.terminal_recovery",
      "github-devloop-pr.devloop_observe_pr -> github-devloop-pr.observe_pr",
    })
    local refused = graph.require_raise(trace, "github-proxy.github_comment_refused")
    t.eq(refused.payload.reason, "head-advanced")
    t.eq(refused.payload.current_head_sha, "feedface")
    t.eq(graph.find_raise(trace, "github-proxy.github_comment_written"), nil)
    t.eq(h.count_calls("gh api --method POST repos/owner/repo/issues/7/comments"), 0)
  end,

  test_run_graph_decompose_refusal_redrives_observer = function()
    local payload = refusal("decompose")
    mock_env()
    mock_observer_after_head_advance(payload.bound_version, true)

    local trace = graph.require_quiescent(graph.run(
      initial("github-devloop-decompose.devloop_terminal_refused", payload),
      { max_steps = 4 }
    ))
    graph.assert_covers(trace, {
      "github-devloop-decompose.devloop_terminal_refused -> github-devloop-pr.terminal_recovery",
      "github-devloop-pr.devloop_observe_pr -> github-devloop-pr.observe_pr",
    })
  end,
}
