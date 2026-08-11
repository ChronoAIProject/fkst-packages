local fixture = require("tests.integration_observe_consensus_helpers")
local convergence_shared = fixture.convergence_shared
local h = fixture.h
local conv_rounds = fixture.conv_rounds
local conv_reconcile = fixture.conv_reconcile
local m_builders = fixture.m_builders
local devloop_base = fixture.devloop_base
local t = fixture.t
local core = fixture.core
local action_label = fixture.action_label
local reason_label = fixture.reason_label
local has_value = fixture.has_value
local opts = fixture.opts
local source_ref = fixture.source_ref
local issue = fixture.issue
local reached = fixture.reached
local unresolved = fixture.unresolved
local reconcile = fixture.reconcile
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
local run_result_expecting_failure = fixture.run_result_expecting_failure
local run_loop = fixture.run_loop
local run_reconcile = fixture.run_reconcile
local run_implement = fixture.run_implement
local run_observe_pr = fixture.run_observe_pr
local run_review_pr = fixture.run_review_pr
local run_review_result = fixture.run_review_result
local run_fix = fixture.run_fix
local set_pr_phase_comments = fixture.set_pr_phase_comments
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
local mock_issue_reconcile = fixture.mock_issue_reconcile
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
local mock_branch_exists = fixture.mock_branch_exists
local mock_setup_worktree = fixture.mock_setup_worktree
local deterministic_branch_for = fixture.deterministic_branch_for
local mock_fresh_implement_worktree = fixture.mock_fresh_implement_worktree
local mock_existing_empty_implement_worktree = fixture.mock_existing_empty_implement_worktree
local mock_existing_empty_implement_worktree_reuse = fixture.mock_existing_empty_implement_worktree_reuse
local mock_existing_implement_branch = fixture.mock_existing_implement_branch
local mock_git_commit = fixture.mock_git_commit
local mock_git_push = fixture.mock_git_push
local mock_existing_devloop_worktree = fixture.mock_existing_devloop_worktree
local mock_implement_codex = fixture.mock_implement_codex
local mock_git_status = fixture.mock_git_status
local mock_write_env = fixture.mock_write_env
local mock_bot_env = fixture.mock_bot_env
local mock_issue_view_failure = fixture.mock_issue_view_failure
local count_calls = fixture.count_calls
local find_raise = fixture.find_raise
local find_causal_raise = fixture.find_causal_raise
local take_consensus_proposal = fixture.take_consensus_proposal
local entity_list_cache = require("devloop.entity_list_cache")

return {
  test_observe_opt_in_issue_raises_proposal_and_thinking_label = function()
    mock_issue_state({ "fkst-dev:enabled" })

    local result = run_observe(issue(), opts("observe-opt-in"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 3)
    t.eq(result.raises[1].queue, "devloop_consensus_request")
    t.eq(result.raises[1].payload.schema, "consensus.proposal.v1")
    t.eq(result.raises[1].payload.proposal_id, "github-devloop/issue/owner/repo/42")
    t.is_true(#result.raises[1].payload.body < 256)
    t.is_nil(result.raises[1].payload.body:find("Body from GitHub", 1, true))
    t.is_true(result.raises[1].payload.content_fetch:find("runtime-cache:", 1, true) == 1)
    t.is_nil(result.raises[1].payload.content_fetch:find("gh issue", 1, true))
    t.eq(result.raises[1].payload.dedup_key, "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z")
    t.eq(result.raises[1].payload.source_ref.ref, "owner/repo#issue/42")
    t.eq(result.raises[1].payload.worktree, ".")

    local label_raise = find_raise(result.raises, "github-proxy.github_issue_label_request")
    t.eq(label_raise.payload.schema, "github-proxy.label.v1")
    t.eq(label_raise.payload.add_labels[1], "fkst-dev:thinking")
    t.eq(label_raise.payload.issue_number, 42)
    t.eq(count_calls("--json body"), 0)
  end,

  test_observe_self_assigned_non_whitelisted_author_skips_without_fork_or_consensus = function()
    local created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now() - (3 * 60 * 60) - 1)
    mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {}, { "fkst-test-bot" }, "human", created_at)

    local result = run_observe(issue(), opts("observe-non-whitelisted-other-author", {
      FKST_GITHUB_AUTHORIZED_LOGINS = "trusted-human",
    }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_create_request"), nil)
    t.eq(find_raise(result.raises, "devloop_consensus_request"), nil)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_observe_self_assigned_non_whitelisted_thinking_issue_skips_replay = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local marker_version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      {
        body = core.state_marker(proposal_id, "thinking", marker_version),
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now()),
      },
    }, { "fkst-test-bot" }, "human")

    local result = run_observe(issue({
      labels = { "fkst-dev:enabled", "fkst-dev:thinking" },
    }), opts("observe-non-whitelisted-thinking-replay", {
      FKST_GITHUB_AUTHORIZED_LOGINS = "trusted-human",
    }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_create_request"), nil)
    t.eq(find_raise(result.raises, "devloop_consensus_request"), nil)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_liveness_scan_non_whitelisted_thinking_issue_skips_redrive = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local marker_version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", {
      {
        body = core.state_marker(proposal_id, "thinking", marker_version),
        created_at = "2026-06-03T01:02:03Z",
      },
    }, { "fkst-test-bot" }, "human")
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
      stdout = "owner/repo", stderr = "", exit_code = 0,
    })
    t.mock_command(core.gh_issue_list_observe_cmd("owner/repo"), {
      stdout = '[{"number":42,"state":"open","updated_at":"2026-06-03T01:02:03Z"}]\n',
      stderr = "",
      exit_code = 0,
    })

    local result = h.run_department("departments/liveness_scan/main.lua", {
      queue = "devloop_liveness_tick",
      payload = { schema = "github-devloop.tick.v1" },
      ts = "2026-06-03T01:32:03Z",
    }, opts("liveness-scan-non-whitelisted-thinking-redrive", {
      FKST_GITHUB_AUTHORIZED_LOGINS = "trusted-human",
    }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(find_raise(result.raises, "devloop_consensus_request"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
  end,

  test_observe_post_admission_self_held_authorized_human_continues_after_fresh_admission = function()
    local runtime_root = assert(os.getenv("FKST_RUNTIME_ROOT"))
    cache_set(entity_list_cache.poll_epoch_cache_key("owner/repo"), "")
    local recorded, poll_epoch = entity_list_cache.record_poll_epoch(
      "owner/repo",
      "observe-post-admission-human"
    )
    t.is_true(recorded)
    t.mock_command("gh issue list --repo 'owner/repo' --state all --limit 100 --json number,comments,author", {
      stdout = "[]\n",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), {
      stdout = "dev",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), {
      stdout = "integration-fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh pr list --repo 'owner/repo' --state all --limit 100 --json number,headRefName,baseRefName,comments,author", {
      stdout = "[]\n",
      stderr = "",
      exit_code = 0,
    })
    mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {
      m_builders.intake_decision_marker(
        "github-devloop/issue/owner/repo/42",
        "enable",
        "intake/github-devloop/issue/owner/repo/42/v1",
        "standard"
      ),
    }, { "fkst-test-bot" }, "trusted-human")

    local result = run_observe(issue({ poll_token = poll_epoch }), opts("observe-self-held-authorized-human", {
      FKST_RUNTIME_ROOT = runtime_root,
    }))

    t.eq(result.exit_code, 0)
    t.is_true(find_raise(result.raises, "devloop_consensus_request") ~= nil)
    t.eq(count_calls("gh issue list --repo owner/repo --state all"), 1)
    t.eq(count_calls("gh pr list --repo owner/repo --state all"), 1)
  end,

  test_observe_unmanaged_repo_peer_stops_before_claim_or_lifecycle_effects = function()
    local runtime_root = assert(os.getenv("FKST_RUNTIME_ROOT"))
    cache_set(entity_list_cache.poll_epoch_cache_key("owner/repo"), "")
    local recorded, poll_epoch = entity_list_cache.record_poll_epoch(
      "owner/repo",
      "observe-unmanaged-repo-peer"
    )
    t.is_true(recorded)
    t.mock_command("gh issue list --repo 'owner/repo' --state all --limit 100 --json number,comments,author", {
      stdout = '[{"number":7,"comments":[{"body":"<!-- fkst:github-devloop:state:v1 proposal=\\"x\\" state=\\"thinking\\" version=\\"v\\" -->","author":{"login":"trusted-human"}}],"author":{"login":"trusted-human"}}]\n',
      stderr = "",
      exit_code = 0,
    })
    mock_issue_state({ "fkst-dev:enabled" }, "OPEN", {
      m_builders.intake_decision_marker(
        "github-devloop/issue/owner/repo/42",
        "enable",
        "intake/github-devloop/issue/owner/repo/42/v1",
        "standard"
      ),
    }, { "fkst-test-bot" }, "trusted-human")

    local result = run_observe(issue({ poll_token = poll_epoch }), opts("observe-unmanaged-repo-peer", {
      FKST_RUNTIME_ROOT = runtime_root,
    }))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("gh issue list --repo owner/repo --state all"), 1)
    t.eq(count_calls("gh issue edit"), 0)
    t.eq(find_raise(result.raises, "devloop_consensus_request"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_comment_request"), nil)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request"), nil)
  end,

  test_observe_skips_not_opt_in_and_already_stateful = function()
    mock_issue_state({ "bug" })
    local not_opted = run_observe(issue({ labels = { "bug" } }), opts("observe-no-label")) t.eq(not_opted.exit_code, 0) t.eq(#not_opted.raises, 0)
    mock_issue_state({ "fkst-class:expedite" }) local class_only = run_observe(issue({ labels = { "fkst-class:expedite" } }), opts("observe-class-label-only")) t.eq(class_only.exit_code, 0) t.eq(#class_only.raises, 0)
    mock_issue_state({ "fkst-dev:tracking" })
    local tracking = run_observe(issue({ labels = { "fkst-dev:tracking" } }), opts("observe-tracking-label")) t.eq(tracking.exit_code, 0) t.eq(#tracking.raises, 0)

    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", { { body = core.state_marker("github-devloop/issue/owner/repo/42", "thinking", "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"), created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now()) } })
    local thinking = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:thinking" } }), opts("observe-thinking"))
    t.eq(thinking.exit_code, 0)
    t.eq(#thinking.raises, 0)
    t.eq(count_calls("--json body"), 0)
  end,

  test_observe_hold_label_blocks_enabled_issue_backstop = function()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:hold" })
    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:hold" } }), opts("observe-hold-label"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("codex exec"), 0)
  end,

  test_observe_re_derives_labels_and_skips_stale_enabled_payload = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local marker_version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:ready" }, "OPEN", {
      {
        id = "IC_ready_visible",
        body = h.projected_state_comment(proposal_id, "ready", marker_version, "result-marker,ready-label,devloop-ready"),
        created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now()),
      },
    })

    local result = run_observe(issue({ labels = { "fkst-dev:enabled" } }), opts("observe-stale-payload"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local ready = find_raise(result.raises, "devloop_ready").payload
    t.eq(ready.schema, "github-devloop.ready.v1")
    t.eq(ready.ready_hand_off.comment_id, "IC_ready_visible")
    t.eq(ready.ready_hand_off.marker_version, marker_version)
    t.is_true(ready.dedup_key:find("/redrive/ready/1", 1, true) ~= nil)
    t.eq(count_calls("--json body"), 0)
  end,

  test_observe_issue_does_not_reraise_merge_ready_after_pr_handoff = function()
    local event = merge_ready()
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:merge-ready" }, "OPEN", merge_comments(event))

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:merge-ready" } }), opts("observe-issue-merge-ready-self-heal"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(count_calls("--json body"), 0)
  end,

  test_observe_issue_does_not_reraise_merging_after_pr_handoff = function()
    local event = merge_ready()
    local comments = merge_comments(event)
    table.insert(comments, core.state_marker(event.proposal_id, "merging", event.version))
    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:merging" }, "OPEN", comments)

    local result = run_observe(issue({ labels = { "fkst-dev:enabled", "fkst-dev:merging" } }), opts("observe-issue-merging-self-heal"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "restart_transition_anomaly")
    t.eq(count_calls("--json body"), 0)
  end,

  test_observe_uses_current_github_state_not_payload_state = function()
    mock_issue_state({ "fkst-dev:enabled" }, "OPEN")
    mock_issue_body("Body from GitHub")

    local result = run_observe(issue({ state = "CLOSED" }), opts("observe-stale-state"))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 3)
  end,

  test_observe_issue_state_view_failure_errors_for_retry = function()
    mock_issue_view_failure("--json title,body,comments,labels,state,updatedAt,assignees", "forced state failure")

	    local result = run_observe(issue(), opts("observe-state-view-failure"))
	    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
    t.eq(count_calls("--json body"), 0)
  end,

  test_observe_re_raises_until_thinking_label_is_on_issue = function()
    local run_opts = opts("observe-idempotent")
    mock_issue_state({ "fkst-dev:enabled" })

    local first = run_observe(issue(), run_opts)
    t.eq(first.exit_code, 0)
    t.eq(#first.raises, 3)

    mock_issue_state({ "fkst-dev:enabled" })
    local second = run_observe(issue({
      updated_at = "2026-06-03T01:02:04Z",
    }), run_opts)
    t.eq(second.exit_code, 0)
    t.eq(#second.raises, 3)

    mock_issue_state({ "fkst-dev:enabled", "fkst-dev:thinking" }, "OPEN", { { body = core.state_marker("github-devloop/issue/owner/repo/42", "thinking", "github-devloop/issue/owner/repo/42/2026-06-03T01-02-05Z"), created_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now()) } })
    local thinking = run_observe(issue({
      updated_at = "2026-06-03T01:02:05Z",
    }), run_opts)
    t.eq(thinking.exit_code, 0)
    local replay_proposal = find_raise(thinking.raises, "devloop_consensus_request").payload
    t.eq(replay_proposal.dedup_key, "github-devloop/issue/owner/repo/42/2026-06-03T01-02-05Z")
    t.eq(replay_proposal.source_ref.ref, "owner/repo#issue/42")
    t.eq(count_calls("--json body"), 0)
  end,
}
