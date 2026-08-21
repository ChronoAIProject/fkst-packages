local h = require("tests.devloop_core_helpers")
local devloop_git_ops = require("devloop.commands.git_ops")
local core = h.core
local t = h.t

local worktree = "/tmp/fkst-packages-test/github-devloop/runtime/worktrees/devloop-owner-repo-42-force-clean"

local function result(exit_code, stderr, stdout)
  return {
    stdout = stdout or "",
    stderr = stderr or "",
    exit_code = exit_code,
  }
end

local function worktree_list(path)
  return "worktree " .. path .. "\nHEAD abc123\nbranch refs/heads/devloop/test\n\n"
end

local function locked_worktree_list(path, branch, reason)
  return "worktree " .. path
    .. "\nHEAD abc123\nbranch refs/heads/" .. tostring(branch)
    .. "\nlocked " .. tostring(reason) .. "\n\n"
end

local function locked_initializing_worktree_list_without_branch(path)
  return "worktree " .. path .. "\nlocked initializing\n\n"
end

local function path_entry_exists_cmd(path)
  local quoted = "'" .. tostring(path):gsub("'", "'\\''") .. "'"
  return "[ -e " .. quoted .. " ] || [ -L " .. quoted .. " ]"
end

local function mock_force_clean(options)
  local opts = options or {}
  local remove_result = opts.remove_result or result(0)
  local directory_result = opts.directory_result or result(0)
  local prune_result = opts.prune_result or result(0)
  local path_result = opts.path_result or result(1)
  local list_result = opts.list_result or result(0)

  t.mock_command("git worktree remove --force", remove_result)
  if opts.owner_list_result ~= nil then
    t.mock_command("git worktree list --porcelain", opts.owner_list_result)
  end
  if opts.locked_remove_result ~= nil then
    t.mock_command("git worktree remove --force --force", opts.locked_remove_result)
  end
  t.mock_command("rm -rf --", directory_result)
  t.mock_command("git worktree prune", prune_result)
  if directory_result.exit_code ~= 0 then
    return
  end
  if prune_result.exit_code ~= 0 then
    return
  end
  t.mock_command(path_entry_exists_cmd(worktree), path_result)
  if path_result.exit_code ~= 1 then
    return
  end
  t.mock_command("git worktree list --porcelain", list_result)
end

local function count_calls(fragment)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if tostring(call.rendered or ""):find(fragment, 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

local function assert_failure(actual, phase, detail)
  t.is_true(tonumber(actual.exit_code) ~= 0)
  t.is_true(tostring(actual.stderr):find(phase, 1, true) ~= nil)
  t.is_true(tostring(actual.stderr):find(detail, 1, true) ~= nil)
end

return {
  test_force_clean_accepts_an_already_absent_target = function()
    mock_force_clean({
      remove_result = result(128, "fatal: not a working tree"),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60)

    t.eq(actual.exit_code, 0)
    t.eq(count_calls("rm -rf --"), 1)
    t.eq(count_calls("git worktree list --porcelain"), 1)
  end,

  test_force_clean_removes_an_orphan_directory = function()
    mock_force_clean({
      remove_result = result(128, "fatal: is not a working tree"),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60)

    t.eq(actual.exit_code, 0)
    t.eq(count_calls("rm -rf --"), 1)
  end,

  test_force_clean_removes_a_registered_worktree = function()
    mock_force_clean()

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60)

    t.eq(actual.exit_code, 0)
    t.eq(count_calls("git worktree remove --force"), 1)
    t.eq(count_calls("rm -rf --"), 1)
    t.eq(count_calls("git worktree prune"), 1)
  end,

  test_force_clean_preserves_directory_removal_diagnostics = function()
    mock_force_clean({
      remove_result = result(128, "git metadata is busy"),
      directory_result = result(1, "permission denied"),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60)

    assert_failure(actual, "directory-remove", "permission denied")
    t.is_true(actual.stderr:find("git metadata is busy", 1, true) ~= nil)
    t.eq(count_calls("git worktree prune"), 0)
  end,

  test_force_clean_preserves_prune_diagnostics = function()
    mock_force_clean({
      remove_result = result(128, "git metadata is busy"),
      prune_result = result(1, "prune lock failed"),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60)

    assert_failure(actual, "prune", "prune lock failed")
    t.is_true(actual.stderr:find("git metadata is busy", 1, true) ~= nil)
  end,

  test_force_clean_rejects_a_path_entry_including_a_dangling_symlink = function()
    mock_force_clean({
      path_result = result(0),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60)

    assert_failure(actual, "postcondition", "path still exists")
    t.eq(count_calls("[ -L "), 1)
  end,

  test_force_clean_preserves_registration_read_diagnostics = function()
    mock_force_clean({
      list_result = result(128, "worktree list lock failed"),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60)

    assert_failure(actual, "registration-check", "worktree list lock failed")
  end,

  test_force_clean_rejects_a_target_that_remains_registered = function()
    mock_force_clean({
      remove_result = result(128, "git metadata is busy"),
      list_result = result(0, "", worktree_list(worktree)),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60)

    assert_failure(actual, "postcondition", "worktree is still registered")
    t.is_true(actual.stderr:find("git metadata is busy", 1, true) ~= nil)
  end,

  test_force_clean_reclaims_only_the_exact_locked_initializing_owner = function()
    mock_force_clean({
      remove_result = result(128, "fatal: cannot remove a locked working tree"),
      owner_list_result = result(0, "", locked_worktree_list(worktree, "devloop/test", "initializing")),
      locked_remove_result = result(0),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60, {
      locked_initializing_branch = "devloop/test",
    })

    t.eq(actual.exit_code, 0)
    t.eq(count_calls("git worktree remove --force --force"), 1)
    t.eq(count_calls("git worktree list --porcelain"), 2)
  end,

  test_force_clean_reclaims_locked_initializing_owner_without_branch_metadata = function()
    mock_force_clean({
      remove_result = result(128, "fatal: cannot remove a locked working tree"),
      owner_list_result = result(0, "", locked_initializing_worktree_list_without_branch(worktree)),
      locked_remove_result = result(0),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60, {
      locked_initializing_branch = "devloop/test",
    })

    t.eq(actual.exit_code, 0)
    t.eq(count_calls("git worktree remove --force --force"), 1)
  end,

  test_force_clean_preserves_a_non_unique_locked_owner_identity = function()
    local duplicate_registration = locked_worktree_list(worktree, "devloop/test", "initializing")
      .. locked_worktree_list(worktree, "devloop/test", "initializing")
    mock_force_clean({
      remove_result = result(128, "fatal: cannot remove a locked working tree"),
      owner_list_result = result(0, "", duplicate_registration),
      list_result = result(0, "", duplicate_registration),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60, {
      locked_initializing_branch = "devloop/test",
    })

    assert_failure(actual, "owner-check", "not the exact locked initializing owner")
    t.eq(count_calls("git worktree remove --force --force"), 0)
    t.eq(count_calls("rm -rf --"), 0)
  end,

  test_force_clean_preserves_a_live_locked_owner = function()
    mock_force_clean({
      remove_result = result(128, "fatal: cannot remove a locked working tree"),
      owner_list_result = result(0, "", locked_worktree_list(worktree, "devloop/test", "active-owner")),
      list_result = result(0, "", locked_worktree_list(worktree, "devloop/test", "active-owner")),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60, {
      locked_initializing_branch = "devloop/test",
    })

    assert_failure(actual, "owner-check", "not the exact locked initializing owner")
    t.eq(count_calls("git worktree remove --force --force"), 0)
    t.eq(count_calls("rm -rf --"), 0)
  end,

  test_force_clean_preserves_a_mismatched_initializing_owner = function()
    mock_force_clean({
      remove_result = result(128, "fatal: cannot remove a locked working tree"),
      owner_list_result = result(0, "", locked_worktree_list(worktree, "devloop/other", "initializing")),
      list_result = result(0, "", locked_worktree_list(worktree, "devloop/other", "initializing")),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60, {
      locked_initializing_branch = "devloop/test",
    })

    assert_failure(actual, "owner-check", "not the exact locked initializing owner")
    t.eq(count_calls("git worktree remove --force --force"), 0)
    t.eq(count_calls("rm -rf --"), 0)
  end,

  test_force_clean_fails_closed_when_initializing_owner_cannot_be_read = function()
    mock_force_clean({
      remove_result = result(128, "fatal: cannot remove a locked working tree"),
      owner_list_result = result(128, "worktree list lock failed"),
      list_result = result(0, "", locked_worktree_list(worktree, "devloop/test", "initializing")),
    })

    local actual = devloop_git_ops.git_worktree_force_clean(worktree, 60, {
      locked_initializing_branch = "devloop/test",
    })

    assert_failure(actual, "owner-check", "worktree list lock failed")
    t.eq(count_calls("git worktree remove --force --force"), 0)
    t.eq(count_calls("rm -rf --"), 0)
  end,
}
