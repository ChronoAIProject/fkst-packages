local fixture = require("tests.merge_queue_wip_helpers")
local entity_lib = fixture.entity_lib
local devloop_base = fixture.devloop_base
local base_ids = fixture.base_ids
local h = fixture.h
local transition_version = fixture.transition_version
local payloads_builders = fixture.payloads_builders
local m_mq = fixture.m_mq
local t = fixture.t
local core = fixture.core
local entity_read_mocks = fixture.entity_read_mocks
local m_builders = fixture.m_builders
local opts = fixture.opts
local merge_ready = fixture.merge_ready
local ready = fixture.ready
local run_merge = fixture.run_merge
local run_implement = fixture.run_implement
local mock_bot_env = fixture.mock_bot_env
local mock_write_env = fixture.mock_write_env
local mock_issue_merge = fixture.mock_issue_merge
local mock_issue_implement = fixture.mock_issue_implement
local mock_pr_merge = fixture.mock_pr_merge
local mock_merging_comment = fixture.mock_merging_comment
local mock_issue_close = fixture.mock_issue_close
local mock_fresh_implement_worktree = fixture.mock_fresh_implement_worktree
local mock_implement_codex = fixture.mock_implement_codex
local mock_git_status = fixture.mock_git_status
local merge_comments = fixture.merge_comments
local count_calls = fixture.count_calls
local find_raise = fixture.find_raise
local find_causal_raise = fixture.find_causal_raise
local render_comment = fixture.render_comment
local json_string = fixture.json_string
local json_literal = fixture.json_literal
local branch_for_pr = fixture.branch_for_pr
local run_merge_queue_tick = fixture.run_merge_queue_tick
local run_starvation_merge_queue_tick = fixture.run_starvation_merge_queue_tick
local mock_repo_env = fixture.mock_repo_env
local mock_branch_config_env = fixture.mock_branch_config_env
local mock_write_env_many = fixture.mock_write_env_many
local merge_comments_with_origin = fixture.merge_comments_with_origin
local merge_comments_for_event = fixture.merge_comments_for_event
local event_for_pr = fixture.event_for_pr
local mock_claimed_issue_for_event = fixture.mock_claimed_issue_for_event
local mock_queue_pr = fixture.mock_queue_pr
local mock_merge_pr_view = fixture.mock_merge_pr_view
local mock_merged_pr_view = fixture.mock_merged_pr_view
local mock_diff_name_only = fixture.mock_diff_name_only
local mock_current_base_head = fixture.mock_current_base_head
local mock_candidate_head_contains_base = fixture.mock_candidate_head_contains_base
local mock_merge_command = fixture.mock_merge_command
local mock_issue_close_for = fixture.mock_issue_close_for
local mock_queue_list = fixture.mock_queue_list
local predecessor_set_for = fixture.predecessor_set_for

return {
  test_merge_queue_head_orders_by_trusted_merge_ready_time_then_pr_number = function()
    local older = event_for_pr(9, 44, "2026-06-03T00-00-00Z", "aaa111")
    local newer = event_for_pr(7, 42, "2026-06-03T01-02-03Z", "def456")
    mock_bot_env()
    mock_queue_list({ 9, 7 })
    mock_queue_pr(older, "2026-06-03T01:00:00Z")
    mock_queue_pr(newer, "2026-06-03T02:00:00Z")

    local head = m_mq.merge_queue_head(core, "owner/repo", "dev")
    t.eq(head.pr_number, 9)
    t.eq(head.proposal_id, older.proposal_id)

    mock_bot_env()
    local left = event_for_pr(3, 45, "2026-06-03T00-00-00Z", "aaa333")
    local right = event_for_pr(2, 46, "2026-06-03T00-00-00Z", "aaa222")
    mock_queue_list({ 3, 2 })
    mock_queue_pr(left, "2026-06-03T01:00:00Z")
    mock_queue_pr(right, "2026-06-03T01:00:00Z")
    head = m_mq.merge_queue_head(core, "owner/repo", "dev")
    t.eq(head.pr_number, 2)

    mock_bot_env()
    mock_queue_list({ 9, 7 })
    mock_queue_pr(older, "2026-06-03T01:00:00Z", "fixing", older.version .. "/fix/1")
    mock_queue_pr(newer, "2026-06-03T02:00:00Z")
    head = m_mq.merge_queue_head(core, "owner/repo", "dev")
    t.eq(head.pr_number, 7)
    t.eq(head.proposal_id, newer.proposal_id)
  end,

  test_merge_queue_head_treats_missing_marker_time_as_unknown_not_oldest = function()
    local dated = event_for_pr(9, 44, "2026-06-03T00-00-00Z", "aaa111")
    local undated = event_for_pr(7, 42, "2026-06-03T01-02-03Z", "def456")
    mock_bot_env()
    mock_queue_list({ 7, 9 })
    mock_queue_pr(undated, "")
    mock_queue_pr(dated, "2026-06-03T01:00:00Z")

    local head = m_mq.merge_queue_head(core, "owner/repo", "dev")
    t.eq(head.pr_number, 9)
    t.eq(head.proposal_id, dated.proposal_id)
  end,

  test_merge_non_head_holds_without_merge_side_effects = function()
    local current = merge_ready()
    local older = event_for_pr(9, 44, "2026-06-03T00-00-00Z", "aaa111")
    local origin_marker = m_builders.pr_origin_marker(current.proposal_id, "42", "devloop-owner-repo-42-01HY", current.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(current))
    mock_pr_merge({ origin_marker })
    mock_queue_list({ 9 })
    mock_queue_pr(older, "2026-06-03T01:00:00Z")

    local result = run_merge(current, opts("merge-queue-non-head", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 0)
    t.eq(find_raise(result.raises, "github-proxy.github_pr_comment_request"), nil)
  end,

  test_fixing_head_yields_merge_queue_lane = function()
    local current = merge_ready()
    local older = event_for_pr(9, 44, "2026-06-03T00-00-00Z", "aaa111")
    local origin_marker = m_builders.pr_origin_marker(current.proposal_id, "42", "devloop-owner-repo-42-01HY", current.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(current))
    mock_pr_merge({ origin_marker })
    mock_queue_list({ 9 })
    mock_queue_pr(older, "2026-06-03T01:00:00Z", "fixing", older.version .. "/fix/1")

    local result = run_merge(current, opts("merge-queue-fixing-head", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_pr_comment_request"), nil)
  end,

  test_merge_queue_poll_drives_current_head_after_non_head_event_held = function()
    local current = merge_ready()
    local older = event_for_pr(9, 44, "2026-06-03T00-00-00Z", "aabb11")
    local origin_marker = m_builders.pr_origin_marker(current.proposal_id, "42", "devloop-owner-repo-42-01HY", current.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_issue_merge({ "fkst-dev:merge-ready" }, merge_comments(current))
    mock_pr_merge({ origin_marker })
    mock_queue_list({ 9 })
    mock_queue_pr(older, "2026-06-03T01:00:00Z")

    local held = run_merge(current, opts("merge-queue-poll-held", { FKST_GITHUB_WRITE = "1" }))
    t.eq(held.exit_code, 0)
    t.eq(find_raise(held.raises, "github-proxy.github_pr_comment_request"), nil)

    mock_bot_env()
    mock_write_env("1")
    mock_repo_env()
    mock_queue_list({ 7 })
    mock_queue_pr(current, "2026-06-03T02:00:00Z")
    mock_pr_merge(merge_comments_with_origin(current, origin_marker))
    mock_write_env("1")
    mock_claimed_issue_for_event(current, 2)
    mock_pr_merge(merge_comments_with_origin(current, origin_marker))
    mock_pr_merge(merge_comments_with_origin(current, origin_marker))
    mock_merging_comment()
    t.mock_command("gh pr merge '7' --repo 'owner/repo' --merge --match-head-commit 'def456'", {
      stdout = "merged\n",
      stderr = "",
      exit_code = 0,
    })
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "def456", "MERGED", "owner/repo", false, "MERGEABLE", "CLEAN", "COMPLETED", "SUCCESS", "2026-06-03T02:03:04Z")
    mock_issue_close()
    mock_diff_name_only(7, { "packages/a.lua" })
    mock_current_base_head("abc124")
    mock_queue_list({})

    local polled = run_merge_queue_tick(opts("merge-queue-poll-drives-head", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(find_raise(polled.raises, "github-proxy.github_issue_label_request"), nil)
    t.is_true(find_raise(polled.raises, "github-proxy.github_pr_comment_request").payload.body:find("fkst:github-devloop:merged:v1", 1, true) ~= nil)
  end,

  test_queue_starvation_redrive_processes_current_merge_queue_head = function()
    local current = merge_ready()
    local origin_marker = m_builders.pr_origin_marker(current.proposal_id, "42", "devloop-owner-repo-42-01HY", current.version, "dev")
    mock_bot_env()
    mock_repo_env()
    mock_queue_list({ 7 })
    mock_queue_pr(current, "2026-06-03T02:00:00Z")
    mock_claimed_issue_for_event(current, 1)
    mock_pr_merge(merge_comments_with_origin(current, origin_marker))
    mock_queue_list({})

    local result = run_starvation_merge_queue_tick(current, opts("merge-queue-starvation-redrive", {
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    local reconcile = find_raise(result.raises, "github-proxy.github_pr_comment_request")
    t.is_true(reconcile.payload.body:find("fkst:github-devloop:queue-starvation-reconcile:v1", 1, true) ~= nil)
    t.is_true(reconcile.payload.body:find('outcome="head-redriven"', 1, true) ~= nil)
  end,

  test_queue_starvation_redrive_revalidates_fifo_head_before_merge = function()
    local current = merge_ready()
    local older = event_for_pr(9, 44, "2026-06-03T00-00-00Z", "aaa111")
    local origin_marker = m_builders.pr_origin_marker(current.proposal_id, "42", "devloop-owner-repo-42-01HY", current.version, "dev")
    mock_bot_env()
    mock_repo_env()
    mock_queue_list({ 7 })
    mock_queue_pr(current, "2026-06-03T02:00:00Z")
    mock_claimed_issue_for_event(current, 1)
    mock_pr_merge(merge_comments_with_origin(current, origin_marker))
    mock_queue_list({ 9 })
    mock_queue_pr(older, "2026-06-03T01:00:00Z")

    local result = run_starvation_merge_queue_tick(current, opts("merge-queue-starvation-revalidate-head", {
      FKST_GITHUB_REPO = "owner/repo",
    }))

    t.eq(result.exit_code, 0, tostring(result.error or result.stderr))
    t.eq(count_calls("gh pr merge"), 0)
  end,

  test_merge_queue_poll_skips_other_owned_head_before_pr_work = function()
    local current = merge_ready()
    mock_bot_env()
    mock_repo_env()
    mock_queue_list({ 7 })
    mock_queue_pr(current, "2026-06-03T02:00:00Z")
    t.mock_command(core.gh_issue_view_claim_cmd("owner/repo", 42), {
      stdout = '{"labels":[{"name":"fkst-dev:claimed:human"}],"author":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = run_merge_queue_tick(opts("merge-queue-poll-other-owned", {
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_pr_comment_request"), nil)
    t.eq(find_raise(result.raises, "devloop_fixing"), nil)
    t.eq(count_calls("gh pr merge"), 0)
  end,

  test_merge_queue_tick_dispatches_namespaced_queue_to_scan = function()
    -- Regression: the fanout tick is delivered with a NAMESPACED event.queue
    -- ("github-devloop-pr.devloop_merge_queue_tick") in production, while the
    -- department declares the bare name. A bare-only `event.queue ==` compare
    -- dropped the tick into the per-PR merge_ready branch ("unsupported event
    -- payload") so the merge-queue scan never ran, and merge-ready PRs that did
    -- not merge on their first per-PR event were never re-attempted (this was
    -- the long-standing "merge is slow" symptom). The namespaced tick must still
    -- reach the scan, which reads the merge queue.
    mock_bot_env()
    mock_repo_env()
    mock_queue_list({})
    local result = t.run_department("departments/merge_queue/main.lua", {
      queue = "github-devloop-pr.devloop_merge_queue_tick",
      payload = { schema = "github-devloop.merge-queue-tick.v1" },
    }, opts("merge-tick-namespaced-dispatch", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(result.exit_code, 0)
    local scanned_queue = false
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find("pulls?state=open&base=dev", 1, true) ~= nil then
        scanned_queue = true
      end
    end
    t.is_true(scanned_queue)
  end,

  test_merge_queue_poll_routes_blocked_red_head_to_fixing_and_releases_next_green = function()
    local current = merge_ready()
    local older = event_for_pr(9, 44, "2026-06-03T00-00-00Z", "aabb11")
    local origin_marker = m_builders.pr_origin_marker(current.proposal_id, "42", "devloop-owner-repo-42-01HY", current.version, "dev")
    mock_bot_env()
    mock_write_env("1")
    mock_write_env("1")
    mock_repo_env()
    mock_branch_config_env(2)
    mock_queue_list({ 9, 7 })
    mock_queue_pr(older, "2026-06-03T01:00:00Z", nil, nil, "MERGEABLE", "BLOCKED", "COMPLETED", "FAILURE")
    mock_queue_pr(current, "2026-06-03T02:00:00Z")
    mock_merge_pr_view(older, "OPEN", "MERGEABLE", "BLOCKED", "COMPLETED", "FAILURE")
    mock_merge_pr_view(older, "OPEN", "MERGEABLE", "BLOCKED", "COMPLETED", "FAILURE")
    h.mock_required_check_runs_for(older.reviewed_head_sha, "failure")
    h.mock_required_check_runs_for(older.reviewed_head_sha, "failure")
    mock_diff_name_only(9, { "packages/older.lua" })
    mock_claimed_issue_for_event(older, 1)
    t.mock_command("git fetch origin 'pull/9/merge'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("rev-parse FETCH_HEAD", {
      stdout = "abc123\n",
      stderr = "",
      exit_code = 0,
    })
    mock_queue_list({})

    local first_poll = run_merge_queue_tick(opts("merge-queue-poll-red-head", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.is_true(find_causal_raise(first_poll, "devloop_fixing") ~= nil)
    t.eq(find_raise(first_poll.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:fixing")

    mock_bot_env()
    mock_write_env("1")
    mock_repo_env()
    mock_branch_config_env()
    mock_queue_list({ 9, 7 })
    mock_queue_pr(older, "2026-06-03T01:00:00Z", "fixing", older.version .. "/fix/1")
    mock_queue_pr(current, "2026-06-03T02:00:00Z")
    mock_pr_merge(merge_comments_with_origin(current, origin_marker))
    mock_write_env("1")
    mock_claimed_issue_for_event(current, 2)
    mock_pr_merge(merge_comments_with_origin(current, origin_marker))
    mock_pr_merge(merge_comments_with_origin(current, origin_marker))
    mock_merging_comment()
    t.mock_command("gh pr merge '7' --repo 'owner/repo' --merge --match-head-commit 'def456'", {
      stdout = "merged\n",
      stderr = "",
      exit_code = 0,
    })
    mock_pr_merge({ origin_marker }, "devloop-owner-repo-42-01HY", "def456", "MERGED", "owner/repo", false, "MERGEABLE", "CLEAN", "COMPLETED", "SUCCESS", "2026-06-03T02:03:04Z")
    mock_issue_close()
    mock_diff_name_only(7, { "packages/current.lua" })
    mock_current_base_head("abc123")

    local second_poll = run_merge_queue_tick(opts("merge-queue-poll-yields-red-head", {
      FKST_GITHUB_WRITE = "1",
      FKST_GITHUB_REPO = "owner/repo",
    }))
    t.eq(find_raise(second_poll.raises, "github-proxy.github_issue_label_request"), nil)
    t.is_true(find_raise(second_poll.raises, "github-proxy.github_pr_comment_request", function(payload)
      return tostring(payload and payload.body or ""):find("fkst:github-devloop:merged:v1", 1, true) ~= nil
    end) ~= nil)
  end,

  test_speculative_predecessor_set_survives_landed_predecessor = function()
    local predecessor = event_for_pr(5, 41, "2026-06-03T00-00-00Z", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    local current = event_for_pr(7, 42, "2026-06-03T01-02-03Z", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    current.version = current.version .. "/fix/1/fix/2"
    current.review_proposal_id = devloop_base.pr_review_proposal_id("owner/repo", current.pr_number, current.version, current.reviewed_head_sha)
    current.review_dedup_key = "consensus:" .. current.review_proposal_id .. "/review"
    current.dedup_key = "merge-ready/" .. current.proposal_id .. "/" .. current.version
    local fix_version = core._strip_latest_fix_version_suffix(current.version)
    local old_review_version = core._strip_latest_fix_version_suffix(fix_version)
    local old_review_proposal = devloop_base.pr_review_proposal_id("owner/repo", current.pr_number, old_review_version, "cccccccccccccccccccccccccccccccccccccccc")
    local old_review_dedup = "consensus:" .. old_review_proposal .. "/review"
    local predecessor_set = predecessor_set_for(predecessor)
    local comments = merge_comments_for_event(current)
    table.insert(comments, core.state_marker(current.proposal_id, "fixing", fix_version))
    table.insert(comments, m_builders.merge_gate_marker(current.proposal_id,
      current.pr_number,
      fix_version,
      old_review_proposal,
      old_review_dedup,
      "cccccccccccccccccccccccccccccccccccccccc",
      "1111111111111111111111111111111111111111",
      "mergeable-conflicting",
      predecessor_set
    ))
    table.insert(comments, m_builders.fix_marker(current.proposal_id, old_review_proposal, old_review_dedup, "cccccccccccccccccccccccccccccccccccccccc", current.reviewed_head_sha))
    mock_bot_env()
    mock_write_env("1")
    mock_branch_config_env(4)
    mock_issue_merge({ "fkst-dev:merge-ready" }, comments)
    mock_pr_merge(comments, branch_for_pr(current.pr_number), current.reviewed_head_sha)
    mock_queue_list({})
    mock_current_base_head("dddddddddddddddddddddddddddddddddddddddd")
    t.mock_command("git merge-base --is-ancestor " .. predecessor.reviewed_head_sha .. " dddddddddddddddddddddddddddddddddddddddd", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    mock_write_env("1")
    mock_claimed_issue_for_event(current, 2)
    mock_pr_merge(comments, branch_for_pr(current.pr_number), current.reviewed_head_sha)
    mock_pr_merge(comments, branch_for_pr(current.pr_number), current.reviewed_head_sha)
    mock_current_base_head("dddddddddddddddddddddddddddddddddddddddd")
    t.mock_command("git merge-base --is-ancestor " .. predecessor.reviewed_head_sha .. " dddddddddddddddddddddddddddddddddddddddd", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    mock_merging_comment()
    t.mock_command("gh pr merge '7' --repo 'owner/repo' --merge --match-head-commit '" .. current.reviewed_head_sha .. "'", {
      stdout = "merged\n",
      stderr = "",
      exit_code = 0,
    })
    mock_pr_merge({ m_builders.pr_origin_marker(current.proposal_id, "42", branch_for_pr(current.pr_number), current.version, "dev") }, branch_for_pr(current.pr_number), current.reviewed_head_sha, "MERGED", "owner/repo", false, "MERGEABLE", "CLEAN", "COMPLETED", "SUCCESS", "2026-06-03T02:03:04Z")
    mock_issue_close()

    local result = run_merge(current, opts("merge-speculative-landed-predecessor", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr merge"), 1)
    t.eq(find_raise(result.raises, "devloop_fixing"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.is_true(find_raise(result.raises, "github-proxy.github_pr_comment_request").payload.body:find("fkst:github-devloop:merged:v1", 1, true) ~= nil)
  end,

}
