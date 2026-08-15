local devloop_base = require("devloop.base")
local requests_review = require("devloop.requests.review")
local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")
local devloop_state = require("devloop.state")
local t = h.t
local core = h.core
local opts = h.opts
local fixing = h.fixing
local run_fix = h.run_fix
local mock_issue_fix_for_event = h.mock_issue_fix_for_event
local mock_pr_fix = h.mock_pr_fix
local mock_implement_codex = h.mock_implement_codex
local mock_git_status = h.mock_git_status
local mock_git_commit = h.mock_git_commit
local mock_git_push = h.mock_git_push
local mock_missing_fix_worktree = h.mock_missing_fix_worktree
local mock_outside_stable_root_fix_worktree = h.mock_outside_stable_root_fix_worktree
local mock_existing_fix_worktree = h.mock_existing_fix_worktree
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local count_calls = h.count_calls
local find_raise = h.find_raise
local find_causal_raise = h.find_causal_raise

local function build_reject_comment(event)
  return requests_review.build_review_result_comment_request(core.output_language,     "owner/repo",
    "42",
    event.proposal_id,
    event.version,
    {
      proposal_id = event.review_proposal_id,
      decision = "reject",
      body = "Reject because parser must fail closed.",
      blocking_gap = "missing regression guard",
      dedup_key = event.review_dedup_key,
      source_ref = { kind = "external", ref = "owner/repo#pr/7" },
    },
    event.source_ref
  ).body
end

local function mock_fix_recovery_context(event, branch, origin_marker, reject_comment, impl_version)
  mock_bot_env()
  mock_write_env("1")
  mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, {
    core.state_marker(event.proposal_id, "fixing", event.version),
    reject_comment,
  }, branch, impl_version or event.version)
  mock_pr_fix({ origin_marker }, branch, "def456")
end

local function mock_fix_writeback(event, branch, origin_marker, impl_version)
  mock_implement_codex(0, "fixed after rebuilding worktree")
  mock_git_status(" M packages/github-devloop/core.lua\n")
  mock_git_commit("feedface", branch)
  mock_write_env("1")
  mock_issue_fix_for_event(event, { "fkst-dev:fixing" }, {
    core.state_marker(event.proposal_id, "fixing", event.version),
    build_reject_comment(event),
  }, branch, impl_version or event.version)
  mock_git_push(branch)
  mock_pr_fix({ origin_marker }, branch, "feedface")
end

return {
  test_fix_replays_stale_canonical_worktree_from_reviewed_remote_head = function()
    local event = fixing()
    local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
    local reject_comment = build_reject_comment(event)
    local origin_marker = m_builders.pr_origin_marker(
      event.proposal_id, "42", branch, event.version, "dev")
    mock_fix_recovery_context(event, branch, origin_marker, reject_comment)
    mock_existing_fix_worktree(branch, "cafebabe", nil, {
      reviewed_head_sha = event.reviewed_head_sha,
      local_contains_reviewed = false,
    })
    mock_fix_writeback(event, branch, origin_marker)

    local result = run_fix(event, opts("fix-stale-canonical-worktree", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("git fetch 'origin' '" .. branch .. "'"), 1)
    t.eq(count_calls("refs/remotes/'origin'/'" .. branch .. "'^{commit}"), 1)
    t.eq(count_calls("reset --hard " .. event.reviewed_head_sha), 1)
    t.eq(count_calls("reset --hard refs/heads/" .. branch), 0)
    t.eq(count_calls("git push 'origin' 'feedface:refs/heads/" .. branch .. "'"), 1)
    t.eq(count_calls("force-with-lease"), 0)
    t.eq(find_causal_raise(result, "devloop_reviewing").payload.version,
      core.next_fix_version(event.version))
  end,

  test_fix_fails_closed_when_fetched_branch_no_longer_matches_write_gate_head = function()
    local event = fixing()
    local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
    t.mock_command("git fetch 'origin' '" .. branch .. "'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("refs/remotes/'origin'/'" .. branch .. "'^{commit}", {
      stdout = "feedface\n",
      stderr = "",
      exit_code = 0,
    })

    local mechanics = require("departments.fix.merge_mechanics").make(core)
    local ok, err = pcall(function()
      mechanics.branch_worktree(
        "owner/repo", "42", event.version, branch, event.reviewed_head_sha)
    end)

    t.eq(ok, false)
    t.is_true(tostring(err or ""):find(
      "git-pr-head-branch-mismatch", 1, true) ~= nil)
    t.eq(count_calls("git fetch 'origin' '" .. branch .. "'"), 1,
      "PR branch is fetched before comparison")
    t.eq(count_calls("FKST_DURABLE_ROOT"), 0)
    t.eq(count_calls("git worktree"), 0)
  end,

  test_fix_uses_immutable_pr_origin_version_for_canonical_worktree = function()
    local event = fixing()
    local origin_impl_version = devloop_state._strip_latest_fix_version_suffix(event.version)
    t.is_true(origin_impl_version ~= event.version)
    local branch = devloop_base.implement_branch("owner/repo", "42", origin_impl_version)
    local reject_comment = build_reject_comment(event)
    local origin_marker = m_builders.pr_origin_marker(
      event.proposal_id, "42", branch, origin_impl_version, "dev")
    mock_fix_recovery_context(
      event, branch, origin_marker, reject_comment, origin_impl_version)
    mock_missing_fix_worktree(branch, "def456")
    mock_fix_writeback(event, branch, origin_marker, origin_impl_version)

    local result = run_fix(event, opts("fix-origin-implementation-worktree", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    local stable_root = devloop_base.implementation_worktree_root(
      "/tmp/fkst-packages-test/github-devloop/durable")
    local expected = devloop_base.implement_worktree_path(
      stable_root, "owner/repo", "42", origin_impl_version)
    local fix_round_path = devloop_base.implement_worktree_path(
      stable_root, "owner/repo", "42", event.version)
    local codex_call = nil
    for _, call in ipairs(t.command_calls()) do
      if tostring(call.rendered or ""):find("codex exec", 1, true) ~= nil then
        codex_call = tostring(call.rendered)
      end
    end
    t.is_true(codex_call ~= nil)
    t.is_true(codex_call:find(expected, 1, true) ~= nil)
    t.eq(codex_call:find(fix_round_path, 1, true), nil)
  end,

  test_fix_rebuilds_missing_recorded_worktree_under_stable_root = function()
    local event = fixing()
    local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
    local reject_comment = build_reject_comment(event)
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev")
    mock_fix_recovery_context(event, branch, origin_marker, reject_comment)
    mock_missing_fix_worktree(branch, "def456")
    mock_fix_writeback(event, branch, origin_marker)

    local result = run_fix(event, opts("fix-rebuild-missing-worktree", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.eq(find_raise(result.raises, "github-proxy.github_issue_label_request").payload.add_labels[1], "fkst-dev:reviewing")
    t.eq(find_causal_raise(result, "devloop_reviewing").payload.version, core.next_fix_version(event.version))
    t.eq(count_calls("git worktree prune"), 1)
    t.eq(count_calls("git fetch 'origin' '" .. branch .. "'"), 1)
    t.eq(count_calls("git worktree add --force -B"), 1)
    t.eq(count_calls("refs/remotes/'origin'/'" .. branch .. "'"), 1)

    local found_stable_root_worktree = false
    for _, call in ipairs(t.command_calls()) do
      if call.rendered:find("codex exec", 1, true) ~= nil
        and call.rendered:find("/tmp/fkst-packages-test/github-devloop/durable-worktrees/worktrees/devloop-owner-repo-42-", 1, true) ~= nil then
        found_stable_root_worktree = true
      end
    end
    t.eq(found_stable_root_worktree, true)
  end,

  test_fix_removes_existing_outside_stable_root_worktree_before_rebuild = function()
    local event = fixing()
    local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
    local reject_comment = build_reject_comment(event)
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev")
    mock_fix_recovery_context(event, branch, origin_marker, reject_comment)
    mock_outside_stable_root_fix_worktree(branch, "def456")
    mock_fix_writeback(event, branch, origin_marker)

    local result = run_fix(event, opts("fix-rebuild-outside-stable-root-worktree", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.eq(count_calls("git worktree remove --force"), 1)
    t.eq(count_calls("git worktree prune"), 0)
    t.eq(count_calls("git fetch 'origin' '" .. branch .. "'"), 1)
    t.eq(count_calls("git worktree add --force -B"), 1)

    local found_stable_root_worktree = false
    for _, call in ipairs(t.command_calls()) do
      if call.rendered:find("codex exec", 1, true) ~= nil
        and call.rendered:find("/tmp/fkst-packages-test/github-devloop/durable-worktrees/worktrees/devloop-owner-repo-42-", 1, true) ~= nil then
        found_stable_root_worktree = true
      end
    end
    t.eq(found_stable_root_worktree, true)
  end,

  test_fix_removes_noncanonical_worktree_inside_stable_root_before_rebuild = function()
    local event = fixing()
    local branch = devloop_base.implement_branch("owner/repo", "42", event.version)
    local reject_comment = build_reject_comment(event)
    local origin_marker = m_builders.pr_origin_marker(event.proposal_id, "42", branch, event.version, "dev")
    mock_fix_recovery_context(event, branch, origin_marker, reject_comment)
    mock_outside_stable_root_fix_worktree(
      branch,
      "def456",
      "/tmp/fkst-packages-test/github-devloop/durable-worktrees/worktrees/noncanonical-fix-worktree"
    )
    mock_fix_writeback(event, branch, origin_marker)

    local result = run_fix(event, opts("fix-rebuild-noncanonical-stable-worktree", { FKST_GITHUB_WRITE = "1" }))
    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 2)
    t.eq(count_calls("git worktree remove --force"), 1)
    t.eq(count_calls("git fetch 'origin' '" .. branch .. "'"), 1)
    t.eq(count_calls("git worktree add --force -B"), 1)

    local used_canonical_worktree = false
    for _, call in ipairs(t.command_calls()) do
      if call.rendered:find("codex exec", 1, true) ~= nil
        and call.rendered:find("/tmp/fkst-packages-test/github-devloop/durable-worktrees/worktrees/devloop-owner-repo-42-", 1, true) ~= nil then
        used_canonical_worktree = true
      end
    end
    t.eq(used_canonical_worktree, true)
  end,
}
