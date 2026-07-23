local devloop_base = require("devloop.base")
local devloop_commands = require("devloop.commands")
local config = require("devloop.config")
local payloads_builders = require("devloop.payloads.builders")
local branch_progress = require("departments.implement.branch_progress")
local substrate_pin = require("departments.implement.substrate_pin")
local devloop_logging = require("devloop.logging")

local exec_sync = exec_sync

local M = {}

local function implementation_outcome(ready, worktree, branch, head_sha, base_branch, base_sha, attempt, started_at, exec_ref)
  return {
    kind = "implementing",
    ready = ready,
    worktree = worktree,
    branch = branch,
    head_sha = head_sha,
    base_branch = base_branch,
    base_sha = base_sha,
    attempt = attempt,
    started_at = started_at,
    exec_ref = exec_ref,
    finished_at = now(),
    outcome = "completed-after-timeout",
  }
end

local function checkpoint_outcome(ready, worktree, branch, head_sha, base_branch, base_sha, attempt, started_at, exec_ref, detail)
  return {
    kind = "implement-checkpoint",
    ready = ready,
    worktree = worktree,
    branch = branch,
    head_sha = head_sha,
    base_branch = base_branch,
    base_sha = base_sha,
    attempt = attempt,
    started_at = started_at,
    exec_ref = exec_ref,
    finished_at = now(),
    detail = detail,
    outcome = "checkpointed: codex-failed",
  }
end

local function impl_failed_outcome(ready, reason, detail, attempt, started_at, exec_ref, base_sha)
  return {
    kind = "impl-failed",
    ready = ready,
    reason = reason,
    detail = detail,
    attempt = attempt,
    started_at = started_at,
    exec_ref = exec_ref,
    finished_at = now(),
    base_sha = base_sha,
    outcome = "failed: " .. tostring(reason),
  }
end

M.impl_failed_outcome = impl_failed_outcome

function M.local_iteration_check(worktree)
  local command = "cd " .. devloop_base._shell_single_quote(worktree)
    .. " && " .. config.local_iteration_test_command()
  return exec_sync({ cmd = command, timeout = 7200 })
end

local function run_local_iteration_check(ready, worktree)
  local check = M.local_iteration_check(worktree)
  devloop_logging.log_line(check.exit_code == 0 and "info" or "warn", "implement", ready.proposal_id, "IMPLEMENT_VERIFY", {
    "exit_code=" .. tostring(check.exit_code),
    "reason=pre-handoff-local-iteration",
  })
  local detail = tostring(check.stderr or "")
  if detail == "" then
    detail = tostring(check.stdout or "")
  end
  return check.exit_code == 0, detail
end

function M.clean_branch_head(base_head, branch)
  local head_sha = branch_progress.implemented_branch_head(base_head, branch)
  if head_sha == nil or substrate_pin.is_only_pin_delta(base_head, branch) then
    return nil
  end
  return head_sha
end

function M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
  local add_result = devloop_commands.git_add_all(worktree, 30)
  if add_result.exit_code ~= 0 then
    error("github-devloop: git-add-failed: git add failed: " .. tostring(add_result.stderr))
  end

  local commit_result = devloop_commands.git_commit(worktree, payloads_builders.implement_commit_subject(
      issue_number,
      require("devloop.github_proxy_entity_view").commit_issue_subject_snapshot(repo, issue_number)
    ), 60)
  if commit_result.exit_code ~= 0 then
    error("github-devloop: git-commit-failed: git commit failed: " .. tostring(commit_result.stderr))
  end

  local branch_result = devloop_commands.git_current_branch(worktree, 30)
  if branch_result.exit_code ~= 0 then
    error("github-devloop: branch-fact-read-failed: git branch fact failed: " .. tostring(branch_result.stderr))
  end
  local actual_branch = tostring(branch_result.stdout or ""):gsub("%s+$", "")
  if actual_branch ~= branch then
    error("github-devloop: branch-mismatch: deterministic implementing branch mismatch")
  end
  if not require("devloop.pr_safety").is_safe_branch(branch) then
    error("github-devloop: unsafe-branch: unsafe implementing branch")
  end

  local head_result = require("forge.git").production_handle("github-devloop").git_head_sha(worktree, 30)
  if head_result.exit_code ~= 0 then
    error("github-devloop: git-head-read-failed: git head fact failed: " .. tostring(head_result.stderr))
  end
  local head_sha = tostring(head_result.stdout or ""):gsub("%s+$", "")
  if not require("devloop.pr_safety").is_safe_head_sha(head_sha) then
    error("github-devloop: unsafe-head-sha: unsafe implementing head_sha")
  end
  return head_sha
end

function M.after_codex_success(repo, issue_number, ready, integration_branch, branch, base_head, worktree, attempt, started_at, exec_ref, head_sha)
  local green, verify_detail = run_local_iteration_check(ready, worktree)
  if not green then
    return impl_failed_outcome(ready, "local-iteration-failed", verify_detail, attempt, started_at, exec_ref, base_head)
  end
  local verified_head = head_sha or M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
  return implementation_outcome(ready, worktree, branch, verified_head, integration_branch, base_head, attempt, started_at, exec_ref)
end

function M.after_codex_failure(repo, issue_number, ready, integration_branch, branch, base_head, worktree, attempt, started_at, exec_ref, stderr)
  local status = devloop_commands.git_status(worktree, 30)
  if status.exit_code ~= 0 then
    error("github-devloop: git-status-failed: git status failed: " .. tostring(status.stderr))
  end
  local dirty = tostring(status.stdout or "") ~= ""
  local existing_head = M.clean_branch_head(base_head, branch)
  local green = false
  local verify_detail = ""
  if dirty or existing_head ~= nil then
    green, verify_detail = run_local_iteration_check(ready, worktree)
  end
  if green then
    local head_sha = dirty and M.commit_dirty_worktree(repo, issue_number, ready, worktree, branch)
      or existing_head
    if head_sha ~= nil then
      return implementation_outcome(ready, worktree, branch, head_sha, integration_branch, base_head, attempt, started_at, exec_ref)
    end
  end
  if existing_head ~= nil then
    return checkpoint_outcome(ready, worktree, branch, existing_head, integration_branch, base_head, attempt, started_at, exec_ref, verify_detail ~= "" and verify_detail or stderr)
  end
  return impl_failed_outcome(ready, "codex-failed", stderr, attempt, started_at, exec_ref, base_head)
end

return M
