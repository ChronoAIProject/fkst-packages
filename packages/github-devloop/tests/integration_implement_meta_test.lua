local fixture = require("tests.integration_implement_meta_helpers")
local entity_lib = fixture.entity_lib
local h = fixture.h
local forks = fixture.forks
local payloads_builders = fixture.payloads_builders
local m_facts = fixture.m_facts
local t = fixture.t
local core = fixture.core
local gh_argv = fixture.gh_argv
local action_label = fixture.action_label
local reason_label = fixture.reason_label
local has_value = fixture.has_value
local opts = fixture.opts
local source_ref = fixture.source_ref
local issue = fixture.issue
local reached = fixture.reached
local unresolved = fixture.unresolved
local ready = fixture.ready
local reviewing = fixture.reviewing
local review_reached = fixture.review_reached
local review_unresolved = fixture.review_unresolved
local fixing = fixture.fixing
local pr_link_marker_for_fix = fixture.pr_link_marker_for_fix
local review_meta_event = fixture.review_meta_event
local merge_ready = fixture.merge_ready
local run_observe = fixture.run_observe
local run_result = fixture.run_result
local run_loop = fixture.run_loop
local run_implement = fixture.run_implement
local run_observe_pr = fixture.run_observe_pr
local run_review_pr = fixture.run_review_pr
local run_review_result = fixture.run_review_result
local run_fix = fixture.run_fix
local run_review_loop = fixture.run_review_loop
local run_review_meta = fixture.run_review_meta
local run_merge = fixture.run_merge
local json_string = fixture.json_string
local render_comment = fixture.render_comment
local default_marker_version = fixture.default_marker_version
local mock_issue_state = fixture.mock_issue_state
local state_from_labels = fixture.state_from_labels
local with_default_state_marker = fixture.with_default_state_marker
local mock_issue_body = fixture.mock_issue_body
local mock_issue_result = fixture.mock_issue_result
local mock_issue_loop = fixture.mock_issue_loop
local mock_issue_implement = fixture.mock_issue_implement
local mock_issue_implement_raw = fixture.mock_issue_implement_raw
local mock_issue_reviewing = fixture.mock_issue_reviewing
local mock_issue_review = fixture.mock_issue_review
local mock_issue_fix = fixture.mock_issue_fix
local mock_issue_fix_for_event = fixture.mock_issue_fix_for_event
local mock_issue_review_meta = fixture.mock_issue_review_meta
local mock_issue_merge = fixture.mock_issue_merge
local merge_comments = fixture.merge_comments
local mock_pr_origin = fixture.mock_pr_origin
local mock_pr_merge = fixture.mock_pr_merge
local mock_pr_merge_rollup = fixture.mock_pr_merge_rollup
local mock_merging_comment = fixture.mock_merging_comment
local mock_pr_merge_command = fixture.mock_pr_merge_command
local has_call = fixture.has_call
local mock_issue_close = fixture.mock_issue_close
local merge_comments_with_merging = fixture.merge_comments_with_merging
local mock_pr_fix = fixture.mock_pr_fix
local mock_pr_origin_sequence = fixture.mock_pr_origin_sequence
local mock_pr_head = fixture.mock_pr_head
local mock_pr_diff = fixture.mock_pr_diff
local mock_setup_worktree = fixture.mock_setup_worktree
local deterministic_branch_for = fixture.deterministic_branch_for
local mock_fresh_implement_worktree = fixture.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree = fixture.mock_existing_empty_implement_worktree
local mock_existing_empty_implement_worktree_reuse = fixture.mock_existing_empty_implement_worktree_reuse
local mock_existing_dirty_implement_worktree_reuse = fixture.mock_existing_dirty_implement_worktree_reuse
local mock_outside_runtime_implement_worktree_rebuild = fixture.mock_outside_runtime_implement_worktree_rebuild
local mock_multiple_outside_runtime_implement_worktrees_rebuild = fixture.mock_multiple_outside_runtime_implement_worktrees_rebuild
local mock_existing_implement_branch = fixture.mock_existing_implement_branch
local mock_git_commit = fixture.mock_git_commit
local mock_git_push = fixture.mock_git_push
local mock_existing_devloop_worktree = fixture.mock_existing_devloop_worktree
local mock_implement_codex = fixture.mock_implement_codex
local mock_git_status = fixture.mock_git_status
local mock_branch_diff_paths = fixture.mock_branch_diff_paths
local mock_write_env = fixture.mock_write_env
local mock_bot_env = fixture.mock_bot_env
local mock_issue_view_failure = fixture.mock_issue_view_failure
local count_calls = fixture.count_calls
local find_raise = fixture.find_raise
local codex_status = fixture.codex_status
local m_builders = fixture.m_builders
local find_comment_with = fixture.find_comment_with
local assert_implement_attempt = fixture.assert_implement_attempt
local count_issue_comment_raises = fixture.count_issue_comment_raises
local find_label_with_added = fixture.find_label_with_added
local assert_worktree_ready_state = fixture.assert_worktree_ready_state
local mock_no_implemented_branch_ahead = fixture.mock_no_implemented_branch_ahead

return {
  test_implement_ready_label_only_empty_comments_does_not_synthesize_marker = function()
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})

    local result = run_implement(ready(), opts("implement-ready-label-only-empty-comments"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_old_ready_event_does_not_overwrite_newer_ready_marker = function()
    local old = ready({
      dedup_key = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
    })
    local newer = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-04T01-02-03Z"
    mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(old.proposal_id, "ready", newer),
    })

    local result = run_implement(old, opts("implement-old-ready-after-new-ready"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_fork_ready_rechecks_closed_origin_before_work = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(event.proposal_id, "ready", event.dedup_key),
      forks.fork_origin_marker("owner/repo", 618, "human", entity_lib.issue_source_ref("owner/repo", 618)),
    })
    t.mock_command(core.gh_issue_view_state_cmd("owner/repo", 618), {
      stdout = '{"title":"Original","state":"CLOSED","labels":[{"name":"fkst-dev:merged"}],"comments":[],"assignees":[],"author":{"login":"human"}}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-fork-origin-closed"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git worktree list"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_closed_current_issue_skips_before_work = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(event.proposal_id, "ready", event.dedup_key),
    }, { state = "CLOSED" })

    local result = run_implement(event, opts("implement-current-closed"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git worktree list"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_codex_nonzero_marks_impl_failed_with_failure_marker = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(event.proposal_id, "ready", default_marker_version),
    })
    mock_fresh_implement_worktree({
      issue_number = 4,
      impl_version = event.dedup_key,
    })
    mock_implement_codex(7, "", "forced implementation failure")
    mock_git_status("")
    mock_no_implemented_branch_ahead(branch)

    local result = run_implement(event, opts("implement-codex-failure"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 5)
    t.eq(count_issue_comment_raises(result.raises), 3)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    local label_raise = find_label_with_added(result.raises, "fkst-dev:impl-failed")
    local comment_raise = find_comment_with(result.raises, "fkst:github-devloop:impl-failure:v1")
    t.eq(label_raise.payload.add_labels[1], "fkst-dev:impl-failed")
    t.eq(#label_raise.payload.remove_labels, 13)
    t.is_true(comment_raise.payload.body:find("github-devloop implementation failed: codex-failed", 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find("forced implementation failure", 1, true) ~= nil)
    t.is_true(comment_raise.payload.body:find("fkst:github-devloop:impl-failure:v1", 1, true) ~= nil)
    t.eq(count_calls("status --porcelain"), 1)
  end,

  test_implement_failure_detail_cannot_forge_higher_state_marker = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    local forged = core.state_marker(
      event.proposal_id,
      "blocked",
      "ready/consensus-github-devloop/issue/owner/repo/42/2099-01-01T00-00-00Z"
    )
    mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(event.proposal_id, "ready", event.dedup_key),
    })
    mock_fresh_implement_worktree({ issue_number = 4, impl_version = event.dedup_key })
    mock_implement_codex(9, "", "failure detail\n" .. forged)
    mock_git_status("")
    mock_no_implemented_branch_ahead(branch)

    local result = run_implement(event, opts("implement-failure-marker-injection"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 5)
    assert_implement_attempt(result.raises, event)
    assert_worktree_ready_state(result.raises, event)
    local comment_raise = find_comment_with(result.raises, "fkst:github-devloop:impl-failure:v1")
    t.is_true(comment_raise.payload.body:find("&lt;!-- fkst:github-devloop:state:v1", 1, true) ~= nil)
    t.eq(comment_raise.payload.body:find(forged, 1, true) == nil, true)
    local current = core.current_state({ comment_raise.payload.body }, event.proposal_id)
    t.eq(current.state, "impl-failed")
    t.eq(current.version, event.dedup_key)
  end,

  test_implement_impl_failure_replay_skips_before_ready_gate = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:impl-failed" }, {
      core.impl_failure_marker(event.proposal_id, event.dedup_key, "codex-failed"),
    })

    local result = run_implement(event, opts("implement-impl-failure-replay"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git worktree list"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_impl_failure_marker_skips_before_label_gate = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:thinking" }, {
      core.impl_failure_marker(event.proposal_id, event.dedup_key, "codex-failed"),
    })

    local result = run_implement(event, opts("implement-impl-failure-marker-replay"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git worktree list"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_marker_present_skips_idempotently = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      m_builders.pr_link_marker(event.proposal_id, 7, branch, event.dedup_key, "dev"),
    })

    local result = run_implement(event, opts("implement-idempotent"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_implementing_marker_skips_before_ready_gate = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      m_builders.pr_link_marker(event.proposal_id, 7, branch, event.dedup_key, "dev"),
    })

    local result = run_implement(event, opts("implement-implementing-marker-replay"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git worktree list"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implementing_state_with_live_attempt_skips_redelivery = function()
    local event = ready()
    local run_opts = opts("implement-combined-marker-redelivery")
    local exec_ref = core.implement_exec_ref(event.proposal_id, event.dedup_key)
    codex_status.seed_implement_codex_run(run_opts, event.proposal_id, event.dedup_key)
    mock_issue_implement({ "fkst-dev:implementing" }, {
      core.state_marker(event.proposal_id, "implementing", event.dedup_key),
      core.implement_attempt_marker(event.proposal_id, event.dedup_key, 1, now(), exec_ref),
    })

    local result = run_implement(event, run_opts)
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git worktree list"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_ready_with_live_attempt_without_visible_markers_skips_redelivery = function()
    local event = ready()
    local run_opts = opts("implement-live-run-no-marker-redelivery")
    local branch = deterministic_branch_for(event)
    codex_status.seed_implement_codex_run(run_opts, event.proposal_id, event.dedup_key)
    mock_issue_implement({ "fkst-dev:ready" }, {
      h.projected_state_comment(event.proposal_id, "ready", event.dedup_key),
    })
    mock_existing_dirty_implement_worktree_reuse(nil, branch, "1")
    mock_implement_codex(0, "duplicate implementation should not spawn")

    local result = run_implement(event, run_opts)
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("reset --hard"), 0)
    t.eq(count_calls("clean -fd"), 0)
  end,

  test_implement_skips_foreign_proposal_before_gh_view = function()
    local result = run_implement(ready({
      proposal_id = "autochrono/issue/owner/repo/42",
      dedup_key = "ready/autochrono/issue/owner/repo/42",
    }), opts("implement-foreign"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_implement_retries_until_ready_label_is_visible = function()
    mock_issue_implement({ "fkst-dev:thinking" })

    local pending = run_implement(ready(), opts("implement-ready-pending"))
    t.eq(pending.exit_code, 1)
    t.eq(#pending.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)

    mock_issue_implement({ "fkst-dev:ready" })
    local branch = deterministic_branch_for(ready())
    mock_fresh_implement_worktree("/tmp/fkst-packages-test/github-devloop/runtime")
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("def456", branch)
    mock_issue_implement({ "fkst-dev:ready" })

    local visible = run_implement(ready(), opts("implement-ready-visible"))
    t.eq(visible.exit_code, 0)
    t.eq(#visible.raises, 4)
    assert_implement_attempt(visible.raises, ready())
    assert_worktree_ready_state(visible.raises, ready())
    t.eq(find_label_with_added(visible.raises, "fkst-dev:implementing").payload.add_labels[1], "fkst-dev:implementing")
    t.eq(count_calls("codex exec"), 1)
  end,

  test_implement_rejects_unverified_ready_hand_off_before_marker_visibility = function()
    local event = ready()
    event.ready_hand_off = {
      kind = "own-state-marker",
      proposal_id = event.proposal_id,
      state = "ready",
      marker_version = event.dedup_key,
      event_version = event.dedup_key,
      stage_rank = core.stage_rank("ready"),
      effects = "result-marker,ready-label,devloop-ready",
    }
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})

    local result = run_implement(event, opts("implement-ready-hand-off-marker-pending"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_ready_hand_off_rechecks_state_before_publish = function()
    local event = ready()
    event.ready_hand_off = {
      kind = "own-state-marker",
      proposal_id = event.proposal_id,
      state = "ready",
      marker_version = event.dedup_key,
      event_version = event.dedup_key,
      stage_rank = core.stage_rank("ready"),
      effects = "result-marker,ready-label,devloop-ready",
      comment_id = "IC_ready_stale",
    }
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/IC_ready_stale'", {
      stdout = '{"body":"' .. json_string(h.projected_state_comment(event.proposal_id, "ready", event.ready_hand_off.marker_version, "result-marker,ready-label,devloop-ready")) .. '","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
    mock_issue_implement_raw({ "fkst-dev:fixing" }, {
      core.state_marker(event.proposal_id, "fixing", event.dedup_key),
    })

    local result = run_implement(event, opts("implement-ready-hand-off-stale-at-write"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git worktree list"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_replay_with_ready_hand_off_requires_visible_marker = function()
    local event = ready()
    event.ready_hand_off = {
      kind = "own-state-marker",
      proposal_id = event.proposal_id,
      state = "ready",
      marker_version = event.dedup_key,
      event_version = event.dedup_key,
      stage_rank = core.stage_rank("ready"),
      effects = "result-marker,ready-label,devloop-ready",
      comment_id = "IC_ready_missing",
    }
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/IC_ready_missing'", {
      stdout = "",
      stderr = "not found",
      exit_code = 1,
    })

    local result = run_implement(event, opts("implement-replay-hand-off-marker-pending"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_replay_without_ready_hand_off_requires_visible_marker = function()
    local event = ready()
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})

    local result = run_implement(event, opts("implement-replay-no-hand-off-marker-pending"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_accepts_verified_durable_ready_hand_off_before_marker_visibility = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    event.ready_hand_off = {
      kind = "own-state-marker",
      proposal_id = event.proposal_id,
      state = "ready",
      marker_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
      event_version = event.dedup_key,
      stage_rank = core.stage_rank("ready"),
      effects = "result-marker,ready-label,devloop-ready",
      comment_id = "IC_ready_1",
    }
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    for _ = 1, 2 do
      t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/IC_ready_1'", {
        stdout = '{"body":"' .. json_string(h.projected_state_comment(event.proposal_id, "ready", event.ready_hand_off.marker_version, "result-marker,ready-label,devloop-ready")) .. '","user":{"login":"fkst-test-bot"}}\n',
        stderr = "",
        exit_code = 0,
      })
    end
    mock_fresh_implement_worktree("/tmp/fkst-packages-test/github-devloop/runtime")
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("def456", branch)
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})

    local result = run_implement(event, opts("implement-durable-ready-hand-off-marker-pending"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 4)
    assert_worktree_ready_state(result.raises, event)
    t.eq(find_label_with_added(result.raises, "fkst-dev:implementing").payload.add_labels[1], "fkst-dev:implementing")
    t.eq(count_calls("repos/owner/repo/issues/comments/IC_ready_1"), 1)
    t.eq(count_calls("codex exec"), 1)
  end,

  test_implement_accepts_ready_hand_off_with_alternate_effects_before_marker_visibility = function()
    local event = ready()
    local branch = deterministic_branch_for(event)
    event.ready_hand_off = {
      kind = "own-state-marker",
      proposal_id = event.proposal_id,
      state = "ready",
      marker_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z",
      event_version = event.dedup_key,
      stage_rank = core.stage_rank("ready"),
      effects = "alternate-ready-producer",
      comment_id = "IC_ready_alternate_effects",
    }
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    for _ = 1, 2 do
      t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/IC_ready_alternate_effects'", {
        stdout = '{"body":"' .. json_string(h.projected_state_comment(event.proposal_id, "ready", event.ready_hand_off.marker_version, "alternate-ready-producer")) .. '","user":{"login":"fkst-test-bot"}}\n',
        stderr = "",
        exit_code = 0,
      })
    end
    mock_fresh_implement_worktree("/tmp/fkst-packages-test/github-devloop/runtime")
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("def456", branch)
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})

    local result = run_implement(event, opts("implement-ready-hand-off-alternate-effects"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 4)
    assert_worktree_ready_state(result.raises, event)
    t.eq(find_label_with_added(result.raises, "fkst-dev:implementing").payload.add_labels[1], "fkst-dev:implementing")
    t.eq(count_calls("repos/owner/repo/issues/comments/IC_ready_alternate_effects"), 1)
    t.eq(count_calls("codex exec"), 1)
  end,

  test_implement_rejects_ready_hand_off_when_comment_marker_state_is_not_ready = function()
    local event = ready()
    event.ready_hand_off = {
      kind = "own-state-marker",
      proposal_id = event.proposal_id,
      state = "ready",
      marker_version = event.dedup_key,
      event_version = event.dedup_key,
      stage_rank = core.stage_rank("ready"),
      effects = "alternate-ready-producer",
      comment_id = "IC_ready_wrong_state",
    }
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/IC_ready_wrong_state'", {
      stdout = '{"body":"' .. json_string(core.state_marker(event.proposal_id, "reviewing", event.ready_hand_off.marker_version, "alternate-ready-producer")) .. '","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = run_implement(event, opts("implement-ready-hand-off-wrong-state"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_redrive_hand_off_uses_original_ready_marker_version = function()
    local original_version = "consensus:github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    local redrive = payloads_builders.build_devloop_ready_payload(core, {
      proposal_id = ready().proposal_id,
      dedup_key = original_version .. "/redrive/ready/2",
      source_ref = source_ref(),
      effect_version = original_version,
      include_ready_hand_off = true,
      ready_comment_id = "IC_ready_original",
    })
    local branch = deterministic_branch_for(redrive)
    local marker = h.projected_state_comment(redrive.proposal_id, "ready", original_version, "result-marker,ready-label,devloop-ready")
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    t.mock_command("gh api --method GET 'repos/owner/repo/issues/comments/IC_ready_original'", {
      stdout = '{"body":"' .. json_string(marker) .. '","user":{"login":"fkst-test-bot"}}\n',
      stderr = "",
      exit_code = 0,
    })
    mock_fresh_implement_worktree({ impl_version = redrive.dedup_key })
    mock_implement_codex(0, "implemented")
    mock_git_status(" M packages/github-devloop/core.lua\n")
    mock_git_commit("def456", branch)
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})

    local result = run_implement(redrive, opts("implement-ready-redrive-original-hand-off"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 4)
    assert_implement_attempt(result.raises, redrive)
    assert_worktree_ready_state(result.raises, redrive)
    t.eq(find_label_with_added(result.raises, "fkst-dev:implementing").payload.add_labels[1], "fkst-dev:implementing")
    t.eq(count_calls("repos/owner/repo/issues/comments/IC_ready_original"), 1)
    t.eq(count_calls("codex exec"), 1)
  end,

  test_implement_retry_ignores_ready_hand_off_before_marker_visibility = function()
    local event = ready({
      impl_retry_attempt = 2,
      ready_hand_off = {
        kind = "own-state-marker",
        proposal_id = ready().proposal_id,
        state = "ready",
        marker_version = ready().dedup_key,
        event_version = ready().dedup_key,
        stage_rank = core.stage_rank("ready"),
        effects = "result-marker,ready-label,devloop-ready",
      },
    })
    mock_issue_implement_raw({ "fkst-dev:ready" }, {})

    local result = run_implement(event, opts("implement-retry-hand-off-marker-pending"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_implementing_label_without_marker_reruns = function()
    mock_issue_implement({ "fkst-dev:implementing" })

    local result = run_implement(ready(), opts("implement-label-without-marker"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_implement_impl_failed_label_without_marker_reruns_and_records_marker = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:impl-failed" })

    local result = run_implement(event, opts("implement-impl-failed-label-without-marker"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("status --porcelain"), 0)
  end,

  test_implement_skips_visible_terminal_states = function()
    local event = ready()
    mock_issue_implement({ "fkst-dev:impl-failed" }, {
      core.state_marker(event.proposal_id, "impl-failed", event.dedup_key),
    })
    local failed_recorded = run_implement(event, opts("implement-already-impl-failed-recorded"))
    t.eq(failed_recorded.exit_code, 0)
    t.eq(#failed_recorded.raises, 0)

    mock_issue_implement({ "fkst-dev:blocked" }, { core.state_marker(event.proposal_id, "blocked", default_marker_version) })
    local blocked = run_implement(event, opts("implement-already-blocked"))
    t.eq(blocked.exit_code, 0)
    t.eq(#blocked.raises, 0)

    t.eq(count_calls("codex exec"), 0)
    t.eq(count_calls("git -C"), 0)
  end,

  test_implement_issue_view_failure_errors_for_retry = function()
    mock_issue_view_failure("--json title,body,labels,comments,state,author", "forced implement failure")

    local result = run_implement(ready(), opts("implement-view-failure"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
  end
}
