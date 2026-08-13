local devloop_base = require("devloop.base")
local impl_failure = require("devloop.impl_failure")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local pr_safety = require("devloop.pr_safety")
local exec_sync = exec_sync
local with_lock = with_lock

local M = {}

function M.worktree_lease_key(branch)
  return "github-devloop/implementation-worktree/" .. tostring(branch)
end

function M.with_worktree_lease(branch, fn)
  local key = M.worktree_lease_key(branch)
  local entered = false
  local ok, result = pcall(function()
    return with_lock(key, function()
      entered = true
      return fn()
    end)
  end)
  if ok then return true, result end
  if not entered and tostring(result):match("^[^\r\n]+") == "with_lock lock busy: " .. key then
    return false
  end
  error(result, 0)
end

local function implementation_root()
  local durable_result = exec_sync({ cmd = devloop_commands.read_durable_root_cmd(), timeout = 30 })
  if durable_result.exit_code ~= 0 then
    error("github-devloop: durable-root-read-failed: FKST_DURABLE_ROOT read failed: " .. tostring(durable_result.stderr))
  end
  return devloop_base.implementation_worktree_root(durable_result.stdout)
end

local function assert_canonical_registration(porcelain, branch, worktree)
  for _, registered in ipairs(devloop_commands.find_worktrees_for_branch(porcelain, branch)) do
    if registered ~= worktree then
      error("github-devloop: worktree-registration-conflict: deterministic branch is registered at "
        .. tostring(registered))
    end
  end
  if devloop_commands.worktree_registered(porcelain, worktree)
    and not devloop_commands.worktree_registered_for_branch(porcelain, worktree, branch) then
    error("github-devloop: worktree-registration-conflict: deterministic worktree is registered to another branch at "
      .. tostring(worktree))
  end
end

function M.prepare_base(branches)
  local fetch_result = devloop_commands.git_fetch_branch("origin", branches.integration, 60)
  if fetch_result.exit_code ~= 0 then
    error("github-devloop: integration-branch-fetch-failed: git integration branch fetch failed: " .. tostring(fetch_result.stderr))
  end
  local base_result = devloop_commands.git_remote_branch_head("origin", branches.integration, 30)
  if base_result.exit_code ~= 0 then
    error("github-devloop: git-head-read-failed: git integration branch head failed: " .. tostring(base_result.stderr))
  end
  local base_head = tostring(base_result.stdout or ""):gsub("%s+$", "")
  if not require("devloop.pr_safety").is_safe_head_sha(base_head) then
    error("github-devloop: unsafe-head-sha: unsafe base head")
  end
  return base_head
end

function M.reconcile_worktree_to_branch(worktree, branch)
  local reset_result = devloop_commands.git_worktree_reset_hard(worktree, branch, 60)
  if reset_result.exit_code ~= 0 then
    error("github-devloop: worktree-reset-failed: git worktree reset failed: " .. tostring(reset_result.stderr))
  end
  local clean_result = devloop_commands.git_worktree_clean(worktree, 60)
  if clean_result.exit_code ~= 0 then
    error("github-devloop: worktree-clean-failed: git worktree clean failed: " .. tostring(clean_result.stderr))
  end
end

function M.merge_integration(git, worktree, integration_branch, base_head)
  local merge_result = devloop_commands.git_worktree_merge_no_edit(worktree, base_head, 120)
  if merge_result.exit_code == 0 then return true end
  local unmerged_result = git.unmerged_paths(worktree, 30)
  if unmerged_result.exit_code ~= 0 then
    error("github-devloop: unmerged-path-check-failed: git unmerged path check failed: " .. tostring(unmerged_result.stderr))
  end
  if tostring(unmerged_result.stdout or "") == "" then
    error("github-devloop: integration-merge-failed: git integration merge failed: " .. tostring(merge_result.stderr))
  end
  devloop_logging.log_line("info", "implement", "merge-target", "MERGE_SKEW", {
    "integration_branch=" .. tostring(integration_branch),
    "integration_sha=" .. tostring(base_head),
    "reason=integration merge requires codex conflict resolution",
  })
  return false
end

local function checkpoint_head_for_branch(checkpoint, branch)
  if type(checkpoint) ~= "table" then
    return nil
  end
  if tostring(checkpoint.branch or "") ~= tostring(branch) then
    return nil
  end
  local head_sha = tostring(checkpoint.head_sha or "")
  if not pr_safety.is_safe_head_sha(head_sha) then
    error("github-devloop: unsafe-head-sha: unsafe checkpoint head")
  end
  return head_sha
end

local function restore_remote_checkpoint_worktree(worktree, branch, checkpoint_head)
  local fetch_result = devloop_commands.git_fetch_branch("origin", branch, 60)
  if fetch_result.exit_code ~= 0 then
    error("github-devloop: checkpoint-branch-fetch-failed: git checkpoint branch fetch failed: " .. tostring(fetch_result.stderr))
  end
  local remote_head_result = devloop_commands.git_remote_branch_head("origin", branch, 30)
  if remote_head_result.exit_code ~= 0 then
    error("github-devloop: checkpoint-head-read-failed: git checkpoint branch head failed: " .. tostring(remote_head_result.stderr))
  end
  local remote_head = tostring(remote_head_result.stdout or ""):gsub("%s+$", "")
  if remote_head ~= checkpoint_head then
    error("github-devloop: checkpoint-head-mismatch: remote checkpoint head does not match marker fact")
  end
  local worktree_result = devloop_commands.git_worktree_add_remote_branch(worktree, "origin", branch, true, 60)
  if worktree_result.exit_code ~= 0 then
    error("github-devloop: git-worktree-add-failed: git worktree add remote checkpoint failed: " .. tostring(worktree_result.stderr))
  end
end

local function canonical_worktree(repo, issue_number, dedup_key, retry_attempt, branch)
  local stable_root = implementation_root()
  local worktree_version = impl_failure.implementation_branch_version(dedup_key, retry_attempt)
  local worktree = devloop_base.implement_worktree_path(
    stable_root, repo, issue_number, worktree_version)
  local list_result = devloop_commands.git_worktree_list(30)
  if list_result.exit_code ~= 0 then
    error("github-devloop: worktree-list-failed: git worktree list failed: " .. tostring(list_result.stderr))
  end
  assert_canonical_registration(list_result.stdout, branch, worktree)
  return worktree, list_result.stdout
end

function M.prepare_worktree(repo, issue_number, ready, branch, base_head, checkpoint)
  local branch_ref = devloop_commands.git_show_ref_branch(branch, 30)
  local branch_exists = branch_ref.exit_code == 0
  local checkpoint_head = checkpoint_head_for_branch(checkpoint, branch)
  if branch_ref.exit_code ~= 0 and branch_ref.exit_code ~= 1 then
    error("github-devloop: branch-ref-check-failed: git branch ref check failed: " .. tostring(branch_ref.stderr))
  end

  local worktree, worktree_list = canonical_worktree(
    repo, issue_number, ready.dedup_key, ready.impl_retry_attempt, branch)
  if checkpoint_head ~= nil then
    local clean_result = devloop_commands.git_worktree_force_clean(worktree, 60)
    if clean_result.exit_code ~= 0 then
      error("github-devloop: worktree-cleanup-failed: git worktree cleanup failed: " .. tostring(clean_result.stderr))
    end
    restore_remote_checkpoint_worktree(worktree, branch, checkpoint_head)
  elseif branch_exists then
    local existing_worktree = devloop_commands.worktree_registered_for_branch(
      worktree_list,
      worktree,
      branch
    ) and worktree or nil
    if existing_worktree ~= nil then
      worktree = existing_worktree
      devloop_logging.log_line("info", "implement", ready.proposal_id, "IMPLEMENT", {
        "branch=" .. tostring(branch),
        "worktree=" .. tostring(worktree),
        "reason=reusing canonical deterministic worktree",
      })
    else
      local clean_result = devloop_commands.git_worktree_force_clean(worktree, 60)
      if clean_result.exit_code ~= 0 then
        error("github-devloop: worktree-cleanup-failed: git worktree cleanup failed: " .. tostring(clean_result.stderr))
      end
      local worktree_result = devloop_commands.git_worktree_add_existing_branch(worktree, branch, 60)
      if worktree_result.exit_code ~= 0 then
        error("github-devloop: git-worktree-add-failed: git worktree add failed: " .. tostring(worktree_result.stderr))
      end
    end
  else
    local clean_result = devloop_commands.git_worktree_force_clean(worktree, 60)
    if clean_result.exit_code ~= 0 then
      error("github-devloop: worktree-cleanup-failed: git worktree cleanup failed: " .. tostring(clean_result.stderr))
    end
    local worktree_result = devloop_commands.git_worktree_add_new_branch(worktree, branch, base_head, 60)
    if worktree_result.exit_code ~= 0 then
      error("github-devloop: git-worktree-add-failed: git worktree add failed: " .. tostring(worktree_result.stderr))
    end
  end
  M.reconcile_worktree_to_branch(worktree, branch)
  return worktree
end

function M.prepare_worktree_from_base(repo, issue_number, ready, branch, base_head)
  local worktree = canonical_worktree(repo, issue_number, ready.dedup_key, ready.impl_retry_attempt, branch)
  local clean_result = devloop_commands.git_worktree_force_clean(worktree, 60)
  if clean_result.exit_code ~= 0 then
    error("github-devloop: worktree-cleanup-failed: git worktree cleanup failed: " .. tostring(clean_result.stderr))
  end
  local worktree_result = devloop_commands.git_worktree_add_reset_branch(worktree, branch, base_head, 60)
  if worktree_result.exit_code ~= 0 then
    error("github-devloop: git-worktree-add-failed: git worktree reset add failed: " .. tostring(worktree_result.stderr))
  end
  return worktree
end

return M
