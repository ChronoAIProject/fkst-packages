local devloop_base = require("devloop.base")
local impl_failure = require("devloop.impl_failure")
local devloop_logging = require("devloop.logging")
local devloop_commands = require("devloop.commands")
local pr_safety = require("devloop.pr_safety")
local git = require("forge.git").production_handle("github-devloop")
local M = {}

local function implementation_root()
  local durable_root
  if type(env_read) == "function" then
    durable_root = env_read("FKST_DURABLE_ROOT")
  else
    local result = exec_sync({ cmd = devloop_commands.read_durable_root_cmd(), timeout = 30 })
    if result.exit_code ~= 0 then
      error("github-devloop: durable-root-read-failed: FKST_DURABLE_ROOT read failed: " .. tostring(result.stderr))
    end
    durable_root = result.stdout
  end
  return devloop_base.implementation_worktree_root(durable_root)
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

local function verify_remote_checkpoint(branch, checkpoint_head)
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
  return checkpoint_head
end

function M.attempt_worktree_template(implementation_worktree_root, repo, issue_number, version, attempt)
  local attempt_number = tonumber(attempt)
  if attempt_number == nil or attempt_number < 1 or attempt_number % 1 ~= 0 then
    error("github-devloop: implementation-attempt-invalid: implementation attempt must be a positive integer")
  end
  local prefix = devloop_base.implement_worktree_path(
    implementation_worktree_root, repo, issue_number, version)
  return prefix .. "-attempt-" .. tostring(attempt_number) .. "-XXXXXX"
end

local function allocate_attempt_worktree(repo, issue_number, ready, attempt)
  local stable_root = implementation_root()
  local worktree_version = impl_failure.implementation_branch_version(
    ready.dedup_key, ready.impl_retry_attempt)
  local template = M.attempt_worktree_template(
    stable_root, repo, issue_number, worktree_version, attempt)
  local parent = template:match("^(.*)/[^/]+$") or "."
  local mkdir_result = exec_sync({ cmd = devloop_commands.mkdir_p_cmd(parent), timeout = 30 })
  if type(mkdir_result) ~= "table" or mkdir_result.exit_code ~= 0 then
    error("github-devloop: worktree-parent-create-failed: implementation worktree parent creation failed: "
      .. tostring(type(mkdir_result) == "table" and mkdir_result.stderr or "missing command result"))
  end
  local create_result = exec_sync({
    cmd = "mktemp -d " .. devloop_base._shell_single_quote(template),
    timeout = 30,
  })
  if type(create_result) ~= "table" or create_result.exit_code ~= 0 then
    error("github-devloop: worktree-allocation-failed: implementation worktree allocation failed: "
      .. tostring(type(create_result) == "table" and create_result.stderr or "missing command result"))
  end
  local worktree = tostring(create_result.stdout or ""):gsub("%s+$", "")
  local prefix = template:sub(1, -7)
  local suffix = worktree:sub(#prefix + 1)
  if worktree:sub(1, #prefix) ~= prefix or suffix == "" or suffix:find("/", 1, true) ~= nil
    or suffix:find("[\r\n]") ~= nil
    or not devloop_base.path_under_root(stable_root, worktree) then
    error("github-devloop: worktree-allocation-invalid: mktemp returned an invalid implementation worktree path")
  end
  return worktree
end

local function add_detached_attempt(repo, issue_number, ready, attempt, head)
  if not pr_safety.is_safe_head_sha(head) then
    error("github-devloop: unsafe-head-sha: unsafe implementation attempt head")
  end
  local worktree = allocate_attempt_worktree(repo, issue_number, ready, attempt)
  local worktree_result = git.git_worktree_add_detached(worktree, head, 60)
  if worktree_result.exit_code ~= 0 then
    error("github-devloop: git-worktree-add-failed: git detached implementation worktree add failed: "
      .. tostring(worktree_result.stderr))
  end
  return worktree
end

function M.prepare_worktree(repo, issue_number, ready, branch, base_head, checkpoint, attempt)
  local checkpoint_head = checkpoint_head_for_branch(checkpoint, branch)
  local start_head = checkpoint_head ~= nil and verify_remote_checkpoint(branch, checkpoint_head) or nil
  if start_head == nil then
    local branch_ref = devloop_commands.git_show_ref_branch(branch, 30)
    if branch_ref.exit_code ~= 0 and branch_ref.exit_code ~= 1 then
      error("github-devloop: branch-ref-check-failed: git branch ref check failed: " .. tostring(branch_ref.stderr))
    end
    if branch_ref.exit_code == 0 then
      local head_result = devloop_commands.git_branch_head(branch, 30)
      if head_result.exit_code ~= 0 then
        error("github-devloop: git-head-read-failed: git implementation branch head failed: "
          .. tostring(head_result.stderr))
      end
      start_head = tostring(head_result.stdout or ""):gsub("%s+$", "")
    else
      start_head = base_head
    end
  end
  return add_detached_attempt(repo, issue_number, ready, attempt, start_head)
end

function M.prepare_worktree_from_base(repo, issue_number, ready, branch, base_head, attempt)
  if not pr_safety.is_safe_branch(branch) then
    error("github-devloop: unsafe-branch: unsafe implementing branch")
  end
  return add_detached_attempt(repo, issue_number, ready, attempt, base_head)
end

return M
