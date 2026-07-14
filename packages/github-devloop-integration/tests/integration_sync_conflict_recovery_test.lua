-- #2275 walking-skeleton: at PR-freshness retry exhaustion, guarded-close the
-- exact stale managed PR (TOCTOU-tight fresh re-read + every mutable precondition
-- re-validated) so the normal observation path produces closed-unmerged and the
-- existing awaiting-pr replay drives one replacement. Branch-sync conflicts and
-- exhausted replacement generations keep the existing terminal escalation.
local h = require("tests.devloop_helpers")
local entity_mocks = require("tests.entity_read_mock_helpers")
local m_builders = require("devloop.markers.builders")
local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local transition_version = require("contract.transition_version")
local payloads_builders = require("devloop.payloads.builders")
local t = h.t
local core = h.core

local repo = "owner/repo"
local pr_number = 77
local issue_number = 42
local parent = base_ids.proposal_id(repo, issue_number)
local integration_branch = "integration/dev"
local upstream_branch = "dev"
local pr_head_branch = "devloop-owner-repo-42-01HY"
local integration_head_sha = "aaaa1111"
local pr_head_sha = "bbbb2222"
local base_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function pr_freshness_payload(extra)
  local payload = {
    schema = "github-devloop.v1",
    repo = repo,
    -- PR-freshness flips the branch fields: upstream = integration branch, the
    -- managed PR head branch is carried in integration_branch, and integration_sha
    -- is the EXPECTED PR head.
    upstream_branch = integration_branch,
    integration_branch = pr_head_branch,
    upstream_sha = integration_head_sha,
    integration_sha = pr_head_sha,
    dedup_key = core.pr_freshness_dedup_key(repo, pr_head_branch, integration_head_sha),
    source_ref = core.pr_freshness_source_ref(repo, pr_number),
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return payload
end

local function opts(name, write)
  return {
    env = {
      FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop/" .. tostring(now()) .. "/" .. tostring(name),
      FKST_GITHUB_WRITE = write == nil and "1" or write,
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
      FKST_DEVLOOP_INTEGRATION_BRANCH = integration_branch,
      FKST_DEVLOOP_UPSTREAM_BRANCH = upstream_branch,
    },
  }
end

local function mock_env(write)
  for _ = 1, 24 do
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_WRITE"), { stdout = write == nil and "1" or write, stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), { stdout = "fkst-test-bot", stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_INTEGRATION_BRANCH"), { stdout = integration_branch, stderr = "", exit_code = 0 })
    t.mock_command(devloop_base.read_env_command("FKST_DEVLOOP_UPSTREAM_BRANCH"), { stdout = upstream_branch, stderr = "", exit_code = 0 })
  end
end

local function mock_conflict_flow(times)
  for _ = 1, times or 1 do
    t.mock_command("git fetch 'origin' '" .. integration_branch .. "'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git fetch 'origin' '" .. pr_head_branch .. "'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("refs/remotes/'origin'/'" .. integration_branch .. "'^{commit}", { stdout = integration_head_sha .. "\n", stderr = "", exit_code = 0 })
    t.mock_command("refs/remotes/'origin'/'" .. pr_head_branch .. "'^{commit}", { stdout = pr_head_sha .. "\n", stderr = "", exit_code = 0 })
    t.mock_command("merge-base --is-ancestor", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', { stdout = "/tmp/fkst-rt", stderr = "", exit_code = 0 })
    t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git worktree add --detach", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("merge --no-ff --no-commit", { stdout = "", stderr = "conflict", exit_code = 1 })
    t.mock_command("ls-files -u", { stdout = "100644 abc 1\tcore.lua\n", stderr = "", exit_code = 0 })
    t.mock_command("git worktree remove --force", { stdout = "", stderr = "", exit_code = 0 })
  end
end

local function seed_attempt_cap(run_opts)
  local fp_conflict = {
    repo = repo,
    upstream_branch = integration_branch,
    integration_branch = pr_head_branch,
    upstream_sha = integration_head_sha,
    integration_sha = pr_head_sha,
  }
  local fingerprint = core.sync_conflict_fingerprint(fp_conflict, "100644 abc 1\tcore.lua\n")
  t.run_department("departments/test_cache_seed/main.lua", {
    queue = "cache_seed",
    payload = {
      key = core.sync_conflict_attempt_key(fp_conflict, fingerprint),
      value = tostring(core.max_sync_conflict_attempts()),
    },
  }, run_opts)
end

local function origin_comment(impl_version)
  return {
    id = "IC_origin",
    body = m_builders.pr_origin_marker(parent, issue_number, pr_head_branch, impl_version or base_version, integration_branch),
    author_login = "fkst-test-bot",
    created_at = "2026-06-03T01:04:03Z",
  }
end

-- Trusted-bot state:v1 marker on the PARENT issue. The recovery guard reads the
-- parent fresh and escalates only when its reimplement round is >= 1 (a
-- replacement generation), because the child pr-origin round is always 0.
local function parent_state_comment(state, version)
  return {
    id = "IC_parent_state_" .. tostring(state),
    body = devloop_state.state_marker(parent, state, version),
    author_login = "fkst-test-bot",
    created_at = "2026-06-03T01:05:03Z",
  }
end

local function mock_parent_issue(comments, times)
  entity_mocks.mock_issue_view_selector(t, {
    repo = repo,
    number = issue_number,
    comments = comments,
    author_login = "fkst-test-bot",
    assignees = { "fkst-test-bot" },
  }, "labels,comments", times or 1)
end

local function mock_fresh_pr(fields)
  local f = {
    repo = repo,
    number = pr_number,
    head = pr_head_branch,
    head_sha = pr_head_sha,
    base_branch = integration_branch,
    state = "OPEN",
    cross_repo = false,
    comments = { origin_comment() },
    labels = {},
  }
  for key, value in pairs(fields or {}) do
    f[key] = value
  end
  entity_mocks.mock_pr_view_selector(t, f, entity_mocks.pr_freshness_selector)
end

local function mock_pr_close(exit_code)
  t.mock_command("gh pr close '" .. tostring(pr_number) .. "' --repo '" .. repo .. "'", {
    stdout = "", stderr = exit_code == 0 and "" or "close failed", exit_code = exit_code or 0,
  })
end

-- Full happy-path recovery setup: pre-codex exhaustion for a PR-freshness
-- conflict, a fresh OPEN managed PR still at the expected head. The PARENT issue
-- defaults to an ORIGINAL generation (awaiting-pr at the round-0 base version), so
-- the recovery guard reads reimplement round 0 and recovers exactly once; pass
-- parent_comments to model a replacement generation (round >= 1).
local function setup_recovery(run_opts, pr_fields, close_exit, parent_comments)
  mock_env(run_opts.env.FKST_GITHUB_WRITE)
  mock_conflict_flow(1)
  seed_attempt_cap(run_opts)
  mock_fresh_pr(pr_fields)
  mock_pr_close(close_exit)
  mock_parent_issue(parent_comments or { parent_state_comment("awaiting-pr", base_version) })
end

local function run_conflict(run_opts)
  return t.run_department("departments/sync_conflict/main.lua", {
    queue = "devloop_sync_conflict",
    payload = pr_freshness_payload(),
  }, run_opts)
end

local function manual_issue(result)
  return h.find_raise(result.raises, "github-proxy.github_issue_create_request")
end

return {
  -- Steps 1+2: managed parent awaiting-pr + original PR at the sync-conflict
  -- attempt cap => exactly ONE guarded close, NO conflict-resolution commit/push,
  -- NO manual-resolution issue.
  test_pr_freshness_exhaustion_closes_stale_pr_once_and_does_not_escalate = function()
    local run_opts = opts("recovery-close")
    setup_recovery(run_opts)

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 1)
    t.eq(h.count_calls("codex exec"), 0)
    t.eq(h.count_calls("commit -F"), 0)
    t.eq(h.count_calls("push origin HEAD:refs/heads/"), 0)
    t.eq(manual_issue(result), nil)
  end,

  -- Dry-run: report would-close WITHOUT mutation.
  test_dry_run_reports_would_close_without_mutation = function()
    local run_opts = opts("recovery-dry-run", "")
    setup_recovery(run_opts)

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 0)
    t.eq(manual_issue(result), nil)
  end,

  -- Already-closed re-read is idempotent success: close nothing, escalate nothing.
  test_already_closed_pr_is_idempotent = function()
    local run_opts = opts("recovery-already-closed")
    setup_recovery(run_opts, { state = "CLOSED" })

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 0)
    t.eq(manual_issue(result), nil)
  end,

  -- Guard: PR head moved between the conflict event and the final re-read =>
  -- fail closed (no close) and keep the terminal escalation.
  test_head_moved_fails_closed_and_escalates = function()
    local run_opts = opts("recovery-head-moved")
    setup_recovery(run_opts, { head_sha = "cccc3333" })

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 0)
    t.is_true(manual_issue(result) ~= nil)
  end,

  -- Guard: PR base is no longer the configured integration branch => fail closed.
  test_base_not_integration_fails_closed = function()
    local run_opts = opts("recovery-base-changed")
    setup_recovery(run_opts, { base_branch = "somewhere-else" })

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 0)
    t.is_true(manual_issue(result) ~= nil)
  end,

  -- Guard: cross-repository PR => fail closed.
  test_cross_repository_fails_closed = function()
    local run_opts = opts("recovery-cross-repo")
    setup_recovery(run_opts, { cross_repo = true })

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 0)
    t.is_true(manual_issue(result) ~= nil)
  end,

  -- Guard: no trusted managed origin marker (self-only parent claim lost) =>
  -- fail closed.
  test_missing_origin_claim_fails_closed = function()
    local run_opts = opts("recovery-no-origin")
    setup_recovery(run_opts, { comments = {} })

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 0)
    t.is_true(manual_issue(result) ~= nil)
  end,

  -- Step 6b: an exhausted REPLACEMENT generation keeps the existing terminal
  -- escalation; no second close/recovery. The markers are DERIVED from the REAL
  -- closed-unmerged -> ready -> awaiting-pr -> implement flow, not a hardcoded
  -- /reimplement/1 pr-origin (which that flow never produces):
  --   * the PARENT issue's state:v1 version is next_reimplement(base) (round 1),
  --     exactly what awaiting_pr_replayer writes on a child closed-unmerged;
  --   * the replacement PR's pr-origin impl_version is the REAL round-0 value,
  --     because build_devloop_ready_payload wraps the round-1 marker and
  --     implementation_attempt_version(ready.dedup_key, nil) STRIPS the trailing
  --     reimplement. The OLD guard keyed on this round-0 pr-origin, so it would
  --     have RECOVERED AGAIN here -> the unbounded destructive loop this fixes.
  test_exhausted_replacement_generation_escalates_without_closing = function()
    local run_opts = opts("recovery-replacement")

    local replacement_marker_version = transition_version.next_reimplement(base_version)
    t.is_true(replacement_marker_version:find("/reimplement/1", 1, true) ~= nil)

    local replacement_ready = payloads_builders.build_devloop_ready_payload(core, {
      proposal_id = parent,
      dedup_key = replacement_marker_version,
      source_ref = core.pr_freshness_source_ref(repo, pr_number),
    })
    -- implement writes the pr-origin impl_version as
    -- implementation_attempt_version(ready.dedup_key, nil), which for a nil attempt
    -- is exactly implementation_base_version == strip_trailing_reimplement.
    local pr_origin_impl_version = transition_version.strip_trailing_reimplement(replacement_ready.dedup_key)
    -- The child pr-origin round is 0: the old guard would NOT have fired on it.
    t.eq(transition_version.trailing_reimplement_round(pr_origin_impl_version), 0)
    -- But the parent's state:v1 round IS >= 1: that is the signal the fix uses.
    t.is_true(devloop_state.version_reimplement_round(replacement_marker_version) >= 1)

    setup_recovery(
      run_opts,
      { comments = { origin_comment(pr_origin_impl_version) } },
      nil,
      { parent_state_comment("ready", replacement_marker_version) }
    )

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 0)
    -- Second freshness exhaustion of a replacement PR escalates: no second close.
    t.eq(h.count_calls("gh pr close"), 0)
    local escalation = manual_issue(result)
    t.is_true(escalation ~= nil)
    -- The escalation is specifically the replacement-generation guard failure (not
    -- head-moved / claim-lost / parent-state-unavailable): the pr-origin claim
    -- matched and the PARENT round drove the decision.
    t.is_true(tostring(escalation.payload.body):find("replacement-generation", 1, true) ~= nil)
  end,

  -- Close failure surfaces as an error (exactly-once key NOT set, so a replay can
  -- re-attempt) and does not silently succeed.
  test_close_failure_surfaces_error = function()
    local run_opts = opts("recovery-close-failure")
    setup_recovery(run_opts, nil, 1)

    local result = run_conflict(run_opts)
    t.eq(result.exit_code, 1)
    t.eq(h.count_calls("gh pr close"), 1)
  end,

  -- Step 6a: replaying the same inputs does NOT close the PR twice. The
  -- exactly-once key set by the first close short-circuits every later replay
  -- BEFORE any second `gh pr close`, and never escalates.
  test_replay_does_not_close_pr_twice = function()
    local run_opts = opts("recovery-replay")
    mock_env(run_opts.env.FKST_GITHUB_WRITE)
    mock_conflict_flow(3)
    seed_attempt_cap(run_opts)
    mock_fresh_pr()
    mock_pr_close(0)
    -- The guard reads the parent only on the FIRST recovery (later replays
    -- short-circuit on the exactly-once close key before the guard); an original
    -- round-0 parent recovers once.
    mock_parent_issue({ parent_state_comment("awaiting-pr", base_version) })

    local first = run_conflict(run_opts)
    t.eq(first.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 1)

    local second = run_conflict(run_opts)
    t.eq(second.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 1)
    t.eq(manual_issue(second), nil)
  end,

  -- Scope 6: a branch-sync conflict (no external repo#pr/N ref) is NOT a
  -- PR-freshness conflict and keeps the EXISTING terminal escalation; it never
  -- closes a PR.
  test_branch_sync_conflict_still_escalates = function()
    local run_opts = opts("branch-sync-escalates")
    local branch_payload = {
      schema = "github-devloop.v1",
      repo = repo,
      upstream_branch = upstream_branch,
      integration_branch = integration_branch,
      upstream_sha = integration_head_sha,
      integration_sha = pr_head_sha,
      dedup_key = core.branch_sync_dedup_key(repo, upstream_branch, integration_branch, integration_head_sha),
      source_ref = core.branch_sync_source_ref(repo, upstream_branch, integration_branch),
    }
    mock_env(run_opts.env.FKST_GITHUB_WRITE)
    t.mock_command("git fetch 'origin' '" .. upstream_branch .. "'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git fetch 'origin' '" .. integration_branch .. "'", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("refs/remotes/'origin'/'" .. upstream_branch .. "'^{commit}", { stdout = integration_head_sha .. "\n", stderr = "", exit_code = 0 })
    t.mock_command("refs/remotes/'origin'/'" .. integration_branch .. "'^{commit}", { stdout = pr_head_sha .. "\n", stderr = "", exit_code = 0 })
    t.mock_command("merge-base --is-ancestor", { stdout = "", stderr = "", exit_code = 1 })
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', { stdout = "/tmp/fkst-rt", stderr = "", exit_code = 0 })
    t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("git worktree add --detach", { stdout = "", stderr = "", exit_code = 0 })
    t.mock_command("merge --no-ff --no-commit", { stdout = "", stderr = "conflict", exit_code = 1 })
    t.mock_command("ls-files -u", { stdout = "100644 abc 1\tcore.lua\n", stderr = "", exit_code = 0 })
    t.mock_command("git worktree remove --force", { stdout = "", stderr = "", exit_code = 0 })

    local fp_conflict = {
      repo = repo,
      upstream_branch = upstream_branch,
      integration_branch = integration_branch,
      upstream_sha = integration_head_sha,
      integration_sha = pr_head_sha,
    }
    local fingerprint = core.sync_conflict_fingerprint(fp_conflict, "100644 abc 1\tcore.lua\n")
    t.run_department("departments/test_cache_seed/main.lua", {
      queue = "cache_seed",
      payload = { key = core.sync_conflict_attempt_key(fp_conflict, fingerprint), value = tostring(core.max_sync_conflict_attempts()) },
    }, run_opts)

    local result = t.run_department("departments/sync_conflict/main.lua", {
      queue = "devloop_sync_conflict",
      payload = branch_payload,
    }, run_opts)
    t.eq(result.exit_code, 0)
    t.eq(h.count_calls("gh pr close"), 0)
    t.is_true(manual_issue(result) ~= nil)
  end,
}
