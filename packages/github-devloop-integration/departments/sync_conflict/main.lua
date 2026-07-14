local git_mechanics = require("devloop.git_mechanics")
local devloop_base = require("devloop.base")
local error_facts = require("contract.error_facts")
local core = require("core")
local config = require("devloop.config")
local git_adapter = require("forge.git")
local saga = require("workflow.saga")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local parsers_pr = require("devloop.parsers.pr")
local m_facts = require("devloop.markers.facts")
local parsers_issue = require("devloop.parsers.issue")
local devloop_state = require("devloop.state")
local base_ids = require("devloop.base_ids")
local devloop_entity_view = require("devloop.github_proxy_entity_view")

local spec = {
  consumes = { "devloop_sync_conflict" },
  produces = { "github-proxy.github_issue_create_request" },
  stall_window = "10m",
}

local git = git_adapter.production_handle

local function trim_stdout(result)
  return tostring(result.stdout or ""):gsub("%s+$", "")
end

local function cleanup_worktree(worktree)
  if worktree == nil then
    return
  end
  local result = core.git.worktree_remove(worktree, 60)
  if result.exit_code ~= 0 then
    devloop_logging.log_line("warn", "sync_conflict", "branch-sync", "CLEANUP", {
      "worktree=" .. tostring(worktree),
      "reason=" .. error_facts.one_line(result.stderr or ""),
    })
  end
end

local function with_temp_worktree(conflict, fn)
  local runtime = git_mechanics.runtime_root_with_exec(exec_sync)
  local worktree = core.branch_sync_worktree_path(
    runtime,
    conflict.repo,
    conflict.upstream_branch,
    conflict.integration_branch,
    conflict.integration_sha
  )
  local plan = git("github-devloop").git_worktree_add_detached_plan(worktree, conflict.integration_sha)
  git_mechanics.run_required(exec_sync({ cmd = devloop_commands.mkdir_p_cmd(plan.parent_dir), timeout = 30 }), "worktree parent directory setup")
  git_mechanics.run_required(git("github-devloop").git_worktree_add_detached(plan.worktree, plan.sha, 60), "worktree add")

  local ok, result = pcall(fn, worktree, runtime)
  cleanup_worktree(worktree)
  if not ok then
    error(result)
  end
  return result
end

local function require_clean_resolution(worktree)
  local unmerged = git_mechanics.run_required(core.git.unmerged_paths(worktree, 30), "unmerged path check")
  if tostring(unmerged.stdout or "") ~= "" then
    return false, tostring(unmerged.stdout or "")
  end
  git_mechanics.run_required(git_mechanics.git_diff_check(core.git, worktree, 30), "diff check")
  git_mechanics.run_required(git_mechanics.git_diff_cached_check(core.git, worktree, 30), "cached diff check")
  return true, ""
end

local function raise_sync_conflict_escalation(conflict, fingerprint, attempt, reason, unmerged_stdout)
  local request = core.build_sync_conflict_escalation_request(
    conflict,
    fingerprint,
    attempt,
    reason,
    unmerged_stdout
  )
  devloop_logging.log_raise("sync_conflict", "branch-sync", "github-proxy.github_issue_create_request", request)
  devloop_logging.log_error_fact("error", "sync_conflict", "branch-sync", "SYNC_CONFLICT_TERMINAL", "sync-conflict-unresolved", "devloop_sync_conflict", reason, {
    source_ref = conflict.source_ref,
    attempt = attempt,
    terminal = true,
  })
end

-- #2275 stale-conflict auto-recovery.
--
-- A PR-freshness conflict carries an external `repo#pr/N` source_ref (a managed
-- PR being refreshed from the integration head); a branch-sync conflict carries
-- a `repo#branch-sync/...` ref. `parse_pr_source_ref` returns non-nil only for
-- the PR-freshness shape, so it is the classifier for the two exhaustion paths.

local function pr_freshness_recovery_close_key(repo, pr_number, head_sha)
  -- Exactly-once key keyed on the exact PR and its EXPECTED head. Set only after
  -- a close is performed (or the PR is observed already-closed), so a replay
  -- never issues a second non-CAS `gh pr close`.
  return base_ids.dedup_key({
    "pr-freshness-recovery-close",
    tostring(repo),
    tostring(pr_number),
    tostring(head_sha),
  })
end

-- Fresh read of the PARENT issue's reimplement round. The #2275 automatic
-- replacement is tracked on the PARENT issue's state:v1 lineage, NOT on the child
-- PR's pr-origin marker: when the original stale PR is closed, awaiting_pr_replayer
-- advances the parent to `ready` at `next_reimplement(...)` (round >= 1) and opens
-- the replacement PR. That replacement PR's own pr-origin `impl_version` is written
-- round-0, because `implementation_attempt_version(ready.dedup_key, nil)` STRIPS the
-- trailing `/reimplement/N` (contrast `implementation_base_version` vs the #2275
-- `implementation_branch_version` in impl_failure.lua). So the child pr-origin round
-- can NEVER distinguish a replacement, but the parent's state:v1 lineage can. Use
-- the append-only MONOTONE round (max across all parent state markers), not a
-- transient current-state cursor read. Returns nil when the parent state cannot
-- be read (caller fails closed).
local function parent_issue_reimplement_round(repo, proposal_id, issue_number)
  local view = devloop_commands.gh_issue_view_result(repo, issue_number, 30)
  if type(view) ~= "table" or view.exit_code ~= 0 then
    return nil
  end
  local parent = parsers_issue.parse_issue_view_result(core, view.stdout)
  return devloop_state.max_reimplement_round(parent.comments, proposal_id)
end

-- Re-validate EVERY mutable precondition from a single FINAL fresh PR view, so
-- the decision is TOCTOU-tight with the close that immediately follows. `not-open`
-- is handled by the caller as idempotent success; every other failure fails
-- closed (close NOTHING) and keeps the existing terminal escalation.
local function pr_freshness_recovery_guard(conflict, pr)
  local integration_branch = config.branch_config().integration
  if pr.is_cross_repository == true then
    return false, "cross-repository"
  end
  if tostring(pr.base_ref_name or "") ~= tostring(integration_branch or "") then
    return false, "base-not-integration"
  end
  if tostring(pr.head_sha or "") ~= tostring(conflict.integration_sha or "") then
    return false, "head-moved"
  end
  local origin = m_facts.pr_origin_fact(pr.comments)
  if origin == nil
    or origin.pr_native == true
    or origin.issue_number == nil
    or tostring(origin.branch or "") ~= tostring(pr.head_ref_name or "")
    or tostring(origin.base_branch or "") ~= tostring(integration_branch or "") then
    -- No trusted managed origin marker held by a single parent claim, or the
    -- claim no longer matches this PR head/base: the self-only parent claim is lost.
    return false, "claim-lost"
  end
  -- #2275 loop termination: recover ONLY an original generation, exactly once.
  -- The reimplement round of a recovery replacement lives on the PARENT issue's
  -- state:v1 version (awaiting_pr_replayer -> next_reimplement), not on this PR's
  -- pr-origin marker (which is written round-0 for a replacement; see
  -- parent_issue_reimplement_round). Read the parent fresh here, keeping the
  -- guarded-close TOCTOU otherwise unchanged: the round only increases (append-only),
  -- so reading it immediately before the close is tight.
  local parent_round = parent_issue_reimplement_round(origin.repo, origin.proposal_id, origin.issue_number)
  if parent_round == nil then
    -- Parent state unavailable: fail closed (close NOTHING), consistent with every
    -- other guard failure, and keep the existing terminal escalation.
    return false, "parent-state-unavailable"
  end
  if parent_round >= 1 then
    -- Parent already reimplemented >= 1: this PR is ALREADY the one automatic
    -- replacement generation. Keep the existing terminal escalation (no second
    -- replacement, no destructive close+re-replace loop).
    return false, "replacement-generation"
  end
  return true, "ok"
end

-- At PR-freshness retry exhaustion: guarded-close the exact stale PR so the
-- normal external observation path (`github-devloop-pr.observe_pr`) produces the
-- trusted `closed-unmerged` fact and the existing awaiting-pr replay drives the
-- parent into a replacement implementation. Never raises a sibling package's
-- internal lifecycle queue directly.
local function recover_exhausted_pr_freshness(conflict, fingerprint, attempt, reason, unmerged_stdout)
  local pr_repo, pr_number = devloop_base.parse_pr_source_ref(conflict.source_ref)
  if pr_repo == nil then
    raise_sync_conflict_escalation(conflict, fingerprint, attempt, reason, unmerged_stdout)
    return
  end
  local pr_state = { state = "pr", version = tostring(conflict.integration_sha or "") }
  local close_key = pr_freshness_recovery_close_key(pr_repo, pr_number, conflict.integration_sha)
  if cache_get(close_key) ~= nil then
    devloop_logging.log_cas_decision("sync_conflict", "pr-freshness", pr_state, "conflict", "recovered", "skip-idempotent(recovery-close-once)", "stale PR already closed once for recovery at this head")
    return
  end

  -- FINAL fresh re-read of the exact PR, immediately before any close decision.
  local view = devloop_commands.gh_pr_view_freshness(pr_repo, pr_number, 30)
  if type(view) ~= "table" or view.exit_code ~= 0 then
    error("github-devloop: pr-freshness-recovery-view-failed: stale PR re-read failed: "
      .. error_facts.one_line(type(view) == "table" and (view.stderr or "") or "nil result"))
  end
  local pr = parsers_pr.parse_pr_view_merge(view.stdout)

  -- Already closed/merged externally: idempotent success. observe_pr owns the
  -- closed-unmerged fact; close nothing here and never re-close.
  if tostring(pr.state or ""):upper() ~= "OPEN" then
    cache_set(close_key, tostring(pr_number))
    devloop_logging.log_cas_decision("sync_conflict", "pr-freshness", pr_state, "conflict", "recovered", "skip-idempotent(already-closed)", "stale PR is already not open")
    return
  end

  local guarded, guard_reason = pr_freshness_recovery_guard(conflict, pr)
  if not guarded then
    devloop_logging.log_cas_decision("sync_conflict", "pr-freshness", pr_state, "conflict", "recovered", "skip-foreign(recovery-guard:" .. guard_reason .. ")", "stale PR recovery guard failed; preserving terminal escalation")
    raise_sync_conflict_escalation(conflict, fingerprint, attempt, reason .. " [recovery guard failed: " .. guard_reason .. "]", unmerged_stdout)
    return
  end

  if config.write_mode() ~= "real" then
    devloop_logging.log_line("info", "sync_conflict", "pr-freshness", "OUTBOUND", {
      "mode=dry-run",
      "repo=" .. tostring(pr_repo),
      "pr=" .. tostring(pr_number),
      "head=" .. tostring(conflict.integration_sha),
      "reason=stale PR would-close for recovery requires FKST_GITHUB_WRITE=1",
    })
    return
  end

  devloop_base.assert_trusted_bot_configured()
  local close_result = devloop_commands.gh_pr_close(pr_repo, pr_number, 60)
  if type(close_result) ~= "table" or close_result.exit_code ~= 0 then
    -- Close failure is transient: the exactly-once key is NOT set, so a replay
    -- re-reads and re-attempts rather than leaving the PR stuck open.
    error("github-devloop: pr-freshness-recovery-close-failed: stale PR close failed: "
      .. error_facts.one_line(type(close_result) == "table" and (close_result.stderr or "") or "nil result"))
  end
  cache_set(close_key, tostring(pr_number))
  devloop_entity_view.invalidate_entity_after_write(pr_repo, "pr", pr_number)
  devloop_logging.log_apply("sync_conflict", "pr-freshness", "recovered", conflict.integration_sha, {}, {})
  devloop_logging.log_cas_decision("sync_conflict", "pr-freshness", pr_state, "conflict", "recovered", "applied(stale-pr-closed)", "closed exhausted stale managed PR to drive closed-unmerged recovery")
end

local function escalate_or_recover(conflict, fingerprint, attempt, reason, unmerged_stdout)
  if devloop_base.parse_pr_source_ref(conflict.source_ref) ~= nil then
    recover_exhausted_pr_freshness(conflict, fingerprint, attempt, reason, unmerged_stdout)
  else
    raise_sync_conflict_escalation(conflict, fingerprint, attempt, reason, unmerged_stdout)
  end
end

local function commit_resolution(worktree, runtime, conflict)
  git_mechanics.run_required(devloop_commands.git_add_all(worktree, 30), "stage conflict resolution")
  local unmerged = git_mechanics.run_required(core.git.unmerged_paths(worktree, 30), "unmerged path check before commit")
  if tostring(unmerged.stdout or "") ~= "" then
    error("github-devloop: sync-conflict-unresolved: sync conflict remains unresolved before commit")
  end
  git_mechanics.run_required(git_mechanics.git_diff_cached_check(core.git, worktree, 30), "cached diff check before commit")
  local message_file = core.branch_sync_message_file(
    runtime,
    conflict.repo,
    conflict.upstream_branch,
    conflict.integration_branch,
    conflict.upstream_sha,
    conflict.integration_sha
  )
  file.write(message_file, core.sync_commit_message(
    conflict.repo,
    conflict.upstream_branch,
    conflict.integration_branch,
    conflict.upstream_sha,
    conflict.integration_sha,
    "resolved"
  ))
  git_mechanics.run_required(core.git.commit_message_file(worktree, message_file, 60), "sync commit")
end

local function push_if_real(conflict, worktree)
  if config.write_mode() ~= "real" then
    devloop_logging.log_line("info", "sync_conflict", "branch-sync", "OUTBOUND", {
      "mode=dry-run",
      "repo=" .. tostring(conflict.repo),
      "upstream=" .. tostring(conflict.upstream_branch),
      "integration=" .. tostring(conflict.integration_branch),
      "upstream_sha=" .. tostring(conflict.upstream_sha),
      "integration_sha=" .. tostring(conflict.integration_sha),
      "reason=resolved branch sync push requires FKST_GITHUB_WRITE=1",
    })
    return
  end

  devloop_base.assert_trusted_bot_configured()
  git_mechanics.fetch_branches(core.git, conflict.repo, { conflict.integration_branch }, "branch fetch")
  local rechecked_integration_sha = git_mechanics.remote_head(core.git, conflict.integration_branch, "remote branch head", "unsafe remote branch head")
  if rechecked_integration_sha ~= conflict.integration_sha then
    devloop_logging.log_cas_decision("sync_conflict", "branch-sync", {
      state = "integration",
      version = rechecked_integration_sha,
    }, "resolved", "push", "skip-foreign(head)", "integration head changed before resolved push")
    return
  end

  local merge_head = trim_stdout(git_mechanics.run_required(git("github-devloop").git_head_sha(worktree, 30), "resolved sync head"))
  if not require("devloop.pr_safety").is_safe_head_sha(merge_head) then
    error("github-devloop: unsafe-head-sha: unsafe resolved branch sync head")
  end
  git_mechanics.run_required(git_mechanics.git_push_worktree_branch_update(core.git, worktree, conflict.integration_branch, 120), "resolved branch sync push")
  git_mechanics.fetch_branches(core.git, conflict.repo, { conflict.integration_branch }, "branch fetch")
  local pushed_head = git_mechanics.remote_head(core.git, conflict.integration_branch, "remote branch head", "unsafe remote branch head")
  if pushed_head ~= merge_head then
    error("github-devloop: push-verification-mismatch: resolved branch sync push verification failed")
  end
  devloop_logging.log_apply("sync_conflict", "branch-sync", "synced", conflict.upstream_sha, {}, {})
end

local function done(_event)
  return false
end

local function act(event)
  local conflict = event.payload or {}
  if not core.is_supported_sync_conflict(conflict) then
    devloop_logging.log_entry("sync_conflict", event, "branch-sync", devloop_logging.payload_field(conflict, "dedup_key"))
    devloop_logging.log_cas_decision("sync_conflict", "branch-sync", { state = nil, version = nil }, "conflict", "resolved", "skip-foreign(payload)", "unsupported sync conflict payload")
    return
  end
  devloop_logging.log_entry("sync_conflict", event, "branch-sync", conflict.dedup_key)

  with_lock(core.branch_sync_lock_key(conflict.repo, conflict.upstream_branch, conflict.integration_branch), function()
    git_mechanics.fetch_branches(core.git, conflict.repo, { conflict.upstream_branch, conflict.integration_branch }, "branch fetch")
    local upstream_sha = git_mechanics.remote_head(core.git, conflict.upstream_branch, "remote branch head", "unsafe remote branch head")
    local integration_sha = git_mechanics.remote_head(core.git, conflict.integration_branch, "remote branch head", "unsafe remote branch head")
    if integration_sha ~= conflict.integration_sha then
      devloop_logging.log_cas_decision("sync_conflict", "branch-sync", { state = "integration", version = integration_sha }, "conflict", "resolved", "skip-stale(integration-head)", "integration head advanced after conflict event")
      return
    end
    if git_mechanics.is_ancestor(core.git, upstream_sha, integration_sha, "ancestor check") then
      devloop_logging.log_cas_decision("sync_conflict", "branch-sync", { state = "synced", version = integration_sha }, "conflict", "resolved", "skip-idempotent(upstream-ancestor)", "conflict resolved elsewhere")
      return
    end

    local active_conflict = {
      schema = conflict.schema,
      repo = conflict.repo,
      upstream_branch = conflict.upstream_branch,
      integration_branch = conflict.integration_branch,
      upstream_sha = upstream_sha,
      integration_sha = conflict.integration_sha,
      dedup_key = conflict.dedup_key,
      source_ref = conflict.source_ref,
    }

    with_temp_worktree(active_conflict, function(worktree, runtime)
      local merge_result = git_mechanics.git_merge_no_ff(core.git, worktree, active_conflict.upstream_sha, 120)
      if merge_result.exit_code == 0 then
        error("github-devloop: sync-conflict-stale: sync conflict event replayed without merge conflict")
      end
      local unmerged = git_mechanics.run_required(core.git.unmerged_paths(worktree, 30), "unmerged path check")
      if tostring(unmerged.stdout or "") == "" then
        error("github-devloop: merge-conflict-state-missing: sync conflict merge failed without unmerged paths")
      end
      local active_fingerprint = core.sync_conflict_fingerprint(active_conflict, tostring(unmerged.stdout or ""))
      local prior_attempts = core.sync_conflict_attempt_count(active_conflict, active_fingerprint)
      if prior_attempts >= core.max_sync_conflict_attempts() then
        escalate_or_recover(
          active_conflict,
          active_fingerprint,
          prior_attempts,
          "sync conflict retry budget already exhausted before codex",
          tostring(unmerged.stdout or "")
        )
        return
      end

      devloop_logging.log_codex_start("sync_conflict", "branch-sync", "sync-conflict")
      local result = spawn_codex_sync({
        prompt = core.build_sync_conflict_prompt(active_conflict),
        worktree = worktree,
      })
      if type(result) ~= "table" or result.exit_code ~= 0 then
        local stderr = type(result) == "table" and result.stderr or "nil result"
        devloop_logging.log_codex_result("sync_conflict", "branch-sync", "sync-conflict", result, nil, stderr, {
          queue = event.queue,
          source_ref = conflict.source_ref,
          terminal = false,
        })
        error("github-devloop: sync-conflict-codex-failed: sync conflict codex failed: " .. tostring(stderr))
      end
      local resolved, remaining_unmerged = require_clean_resolution(worktree)
      if not resolved then
        local fingerprint = core.sync_conflict_fingerprint(active_conflict, remaining_unmerged)
        local previous_attempts = core.sync_conflict_attempt_count(active_conflict, fingerprint)
        local attempt = previous_attempts + 1
        core.record_sync_conflict_attempt(active_conflict, fingerprint, attempt)
        local reason = "sync conflict remains unresolved after codex completed"
        devloop_logging.log_codex_result("sync_conflict", "branch-sync", "sync-conflict", result, nil, reason, {
          queue = event.queue,
          source_ref = conflict.source_ref,
          attempt = attempt,
          terminal = attempt >= core.max_sync_conflict_attempts(),
          error_class = "sync-conflict-unresolved",
        })
        if attempt >= core.max_sync_conflict_attempts() then
          escalate_or_recover(active_conflict, fingerprint, attempt, reason, remaining_unmerged)
          return
        end
        error("github-devloop: sync-conflict-unresolved: " .. reason)
      end
      devloop_logging.log_codex_result("sync_conflict", "branch-sync", "sync-conflict", result, "result=completed", nil)
      commit_resolution(worktree, runtime, active_conflict)
      push_if_real(active_conflict, worktree)
    end)
  end)
end

return saga.department(spec, {
  done = done,
  act = act,
  wrap = devloop_logging.wrap_pipeline_failure,
  name = "sync_conflict",
})
