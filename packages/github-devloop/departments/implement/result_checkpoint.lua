local pr_safety = require("devloop.pr_safety")
local sha256 = require("contract.sha256")

local M = {}

local SUBJECT_PREFIX = "fkst: implementation result v1 "

function M.subject(version)
  local logical_version = tostring(version or "")
  if logical_version == "" then
    error("github-devloop: implementation-result-version-missing: logical implementation version is required")
  end
  return SUBJECT_PREFIX .. sha256.hex(logical_version)
end

local function read_head(git, worktree)
  local head = git.git_head_sha(worktree, 30)
  if head.exit_code ~= 0 then
    error("github-devloop: git-head-read-failed: implementation result head read failed: "
      .. tostring(head.stderr))
  end
  local head_sha = tostring(head.stdout or ""):gsub("%s+$", "")
  if not pr_safety.is_safe_head_sha(head_sha) then
    error("github-devloop: unsafe-head-sha: unsafe implementation result head")
  end
  return head_sha
end

function M.persist(git, worktree, version)
  local receipt = git.git_empty_commit(worktree, M.subject(version), 60)
  if receipt.exit_code ~= 0 then
    error("github-devloop: implementation-result-receipt-failed: git receipt commit failed: "
      .. tostring(receipt.stderr))
  end
  return read_head(git, worktree)
end

function M.reseal(git, worktree, progress, version)
  if type(progress) ~= "table" or not pr_safety.is_safe_head_sha(progress.head_sha) then
    error("github-devloop: implementation-result-receipt-invalid: completed result head is unsafe")
  end
  local current_head = read_head(git, worktree)
  if current_head == progress.head_sha then
    return progress
  end
  local ancestry = git.is_ancestor(progress.head_sha, current_head, 30)
  if ancestry.exit_code == 1 then
    error("github-devloop: implementation-result-receipt-not-ancestor: reconciled head lost completed work")
  end
  if ancestry.exit_code ~= 0 then
    error("github-devloop: implementation-result-receipt-ancestry-failed: git ancestry check failed: "
      .. tostring(ancestry.stderr))
  end
  local resealed = {}
  for key, value in pairs(progress) do
    resealed[key] = value
  end
  resealed.head_sha = M.persist(git, worktree, version)
  return resealed
end

function M.rehydrate(git, progress, version)
  if type(progress) ~= "table" or not pr_safety.is_safe_head_sha(progress.head_sha) then
    return nil
  end
  local commit = git.cat_file_pretty(progress.head_sha, 30)
  if commit.exit_code ~= 0 then
    error("github-devloop: implementation-result-receipt-read-failed: git receipt read failed: "
      .. tostring(commit.stderr))
  end
  local subject = tostring(commit.stdout or ""):match("\n\n([^\r\n]*)")
  if subject ~= M.subject(version) then
    return nil
  end
  return progress
end

return M
