local core = require("core")
local git_adapter = require("forge.git")

local M = {}

local substrate_ref_path = ".fkst/substrate-ref"
local git_handle = nil

local function git(opts)
  if opts ~= nil and opts.git ~= nil then
    return opts.git
  end
  if git_handle == nil then
    if type(exec_argv) ~= "function" then
      error("github-devloop: implement-substrate-pin-git-adapter-unavailable: exec_argv is required")
    end
    git_handle = git_adapter.new(exec_argv)
  end
  return git_handle
end

local function trim(value)
  return tostring(value or ""):gsub("%s+$", "")
end

local function is_missing_pin_result(result)
  if result == nil then
    return true
  end
  if result.exit_code == 0 then
    return false
  end
  local text = tostring(result.stderr or "") .. "\n" .. tostring(result.stdout or "")
  if text:gsub("%s+", "") == "" then
    return true
  end
  return text:find(substrate_ref_path, 1, true) ~= nil
    and (
      text:find(substrate_ref_path .. "' does not exist", 1, true) ~= nil
      or text:find(substrate_ref_path .. "' exists on disk, but not in", 1, true) ~= nil
    )
end

local function show_pin(ref, opts)
  opts = opts or {}
  local result = git(opts).show_file(ref, substrate_ref_path, 30)
  if result == nil or result.exit_code ~= 0 then
    if is_missing_pin_result(result) and opts.missing_ok then
      return nil
    end
    error("github-devloop: implement-substrate-pin-read-failed: " .. tostring(result and result.stderr or "nil git result"))
  end
  local pin = trim(result.stdout)
  if not core._is_git_sha(pin) then
    error("github-devloop: implement-substrate-pin-invalid: invalid implementation substrate-ref pin")
  end
  return pin:lower()
end

local function write_pin(worktree, pin)
  local root = tostring(worktree or ""):gsub("/+$", "")
  if root == "" or root:find("[\r\n]") ~= nil then
    error("github-devloop: implement-substrate-pin-worktree-invalid: invalid implementation worktree path")
  end
  file.write(root .. "/" .. substrate_ref_path, tostring(pin) .. "\n")
end

function M.refresh(worktree, branch, base_head, merge_clean, opts)
  if not core.is_safe_head_sha(base_head) then
    error("github-devloop: implement-substrate-pin-base-unsafe: unsafe implementation base head")
  end
  if not core._is_git_ref_safe(branch) then
    error("github-devloop: implement-substrate-pin-branch-unsafe: unsafe implementation branch")
  end
  local base_pin = show_pin(base_head, { missing_ok = true, git = opts and opts.git })
  if base_pin == nil then
    core.log_line("info", "implement", "substrate-pin", "IMPLEMENT", {
      "reason=no .fkst/substrate-ref to refresh (repo does not pin substrate)",
      "base_head=" .. tostring(base_head),
    })
    return
  end
  local branch_pin = show_pin(branch, { missing_ok = true, git = opts and opts.git })
  if branch_pin == base_pin then
    return
  end

  write_pin(worktree, base_pin)
  if not merge_clean then
    return
  end

  local add = core.git_add_all(worktree, 30)
  if add.exit_code ~= 0 then
    error("github-devloop: implement-substrate-pin-add-failed: " .. tostring(add.stderr))
  end
  local commit = core.git_commit(worktree, "chore: refresh fkst-substrate pin", 60)
  if commit.exit_code ~= 0 then
    error("github-devloop: implement-substrate-pin-commit-failed: " .. tostring(commit.stderr))
  end
end

function M.is_only_pin_delta(base_head, branch)
  if not core.is_safe_head_sha(base_head) then
    error("github-devloop: implement-substrate-pin-base-unsafe: unsafe implementation base head")
  end
  if not core._is_git_ref_safe(branch) then
    error("github-devloop: implement-substrate-pin-branch-unsafe: unsafe implementation branch")
  end
  local diff = git().diff_name_only(nil, tostring(base_head) .. "..refs/heads/" .. tostring(branch), 30)
  if diff.exit_code ~= 0 then
    error("github-devloop: implement-substrate-pin-diff-failed: " .. tostring(diff.stderr))
  end
  local saw_path = false
  for line in (tostring(diff.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      saw_path = true
      if line ~= substrate_ref_path then
        return false
      end
    end
  end
  return saw_path
end

return M
