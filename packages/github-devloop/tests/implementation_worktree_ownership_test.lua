local h = require("tests.devloop_helpers")
local t = h.t
local devloop_base = require("devloop.base")
local impl_failure = require("devloop.impl_failure")
local worktree_lifecycle = require("departments.implement.worktree")

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_output(command)
  local pipe = assert(io.popen(command .. " 2>&1", "r"))
  local output = pipe:read("*a")
  local ok, why, code = pipe:close()
  if ok ~= true then
    error("command failed (" .. tostring(why) .. " " .. tostring(code) .. "): "
      .. command .. "\n" .. tostring(output))
  end
  return output
end

local function run_command(command)
  command_output(command)
end

local function path_exists(path)
  local ok = os.execute("test -e " .. shell_quote(path))
  return ok == true or ok == 0
end

local function remove_fixture(path)
  if tostring(path):match("^/tmp/fkst%-implementation%-attempt%-isolation%.[^/]+$") == nil then
    error("refusing to remove unexpected fixture path: " .. tostring(path))
  end
  os.execute("rm -rf -- " .. shell_quote(path))
end

local function mock_new_attempt_worktree(durable_root, worktree, branch_head)
  t.mock_command("show-ref --verify --quiet", {
    stdout = "",
    stderr = "",
    exit_code = branch_head ~= nil and 0 or 1,
  })
  if branch_head ~= nil then
    t.mock_command("rev-parse --verify refs/heads/", {
      stdout = branch_head .. "\n",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command('printf %s "$FKST_DURABLE_ROOT"', {
    stdout = durable_root,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("mkdir -p", { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("mktemp -d", { stdout = worktree .. "\n", stderr = "", exit_code = 0 })
  t.mock_command("git worktree add --detach", { stdout = "", stderr = "", exit_code = 0 })
end

return {
  test_prepare_does_not_reclaim_worktree_that_owns_canonical_branch = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/noncanonical-durable"
    local ready = h.ready()
    local branch = h.deterministic_branch_for(ready)
    local implementation_root = devloop_base.implementation_worktree_root(durable_root)
    local template = worktree_lifecycle.attempt_worktree_template(
      implementation_root,
      "owner/repo",
      42,
      impl_failure.implementation_branch_version(ready.dedup_key, nil),
      1
    )
    local attempt_worktree = template:gsub("XXXXXX$", "AAAAAA")
    mock_new_attempt_worktree(durable_root, attempt_worktree, "abc123")

    local result = worktree_lifecycle.prepare_worktree(
      "owner/repo", 42, ready, branch, "abc123", nil, 1)

    t.eq(result, attempt_worktree)
    t.eq(h.count_calls("git worktree remove --force"), 0)
    t.eq(h.count_calls("git worktree add --detach"), 1)
    t.eq(h.count_calls("reset --hard"), 0)
    t.eq(h.count_calls("clean -fd"), 0)
  end,

  test_prepare_allocates_one_detached_worktree_per_live_attempt = function()
    local durable_root = "/tmp/fkst-packages-test/github-devloop/attempt-isolation-durable"
    local ready = h.ready()
    local branch = h.deterministic_branch_for(ready)
    local implementation_root = devloop_base.implementation_worktree_root(durable_root)
    local template = worktree_lifecycle.attempt_worktree_template(
      implementation_root,
      "owner/repo",
      42,
      impl_failure.implementation_branch_version(ready.dedup_key, nil),
      1
    )
    local first = template:gsub("XXXXXX$", "AAAAAA")
    local second = template:gsub("XXXXXX$", "BBBBBB")
    mock_new_attempt_worktree(durable_root, first)
    mock_new_attempt_worktree(durable_root, second)

    local first_result = worktree_lifecycle.prepare_worktree(
      "owner/repo", 42, ready, branch, "abc123", nil, 1)
    local second_result = worktree_lifecycle.prepare_worktree(
      "owner/repo", 42, ready, branch, "abc123", nil, 1)

    t.eq(first_result, first)
    t.eq(second_result, second)
    t.is_true(first_result ~= second_result)
    t.eq(h.count_calls("git worktree add --detach"), 2)
    t.eq(h.count_calls("git worktree remove --force"), 0)
    t.eq(h.count_calls("reset --hard"), 0)
    t.eq(h.count_calls("clean -fd"), 0)
  end,

  test_second_attempt_cannot_disturb_first_attempt_tree = function()
    local root = command_output(
      "mktemp -d " .. shell_quote("/tmp/fkst-implementation-attempt-isolation.XXXXXX"))
      :gsub("%s+$", "")
    local ok, err = pcall(function()
      local repo = root .. "/repo"
      local implementation_root = root .. "/durable-worktrees"
      local version = "ready/github-devloop/issue/owner/repo/42/intake/123"
      local template = worktree_lifecycle.attempt_worktree_template(
        implementation_root, "owner/repo", 42, version, 1)

      run_command("git init -b main " .. shell_quote(repo))
      run_command("git -C " .. shell_quote(repo) .. " config user.name " .. shell_quote("FKST Test"))
      run_command("git -C " .. shell_quote(repo) .. " config user.email " .. shell_quote("fkst@example.invalid"))
      run_command("mkdir -p " .. shell_quote(implementation_root .. "/worktrees"))
      run_command("touch " .. shell_quote(repo .. "/base.txt"))
      run_command("git -C " .. shell_quote(repo) .. " add base.txt")
      run_command("git -C " .. shell_quote(repo) .. " commit -m base")

      local first = command_output("mktemp -d " .. shell_quote(template)):gsub("%s+$", "")
      local second = command_output("mktemp -d " .. shell_quote(template)):gsub("%s+$", "")
      run_command("git -C " .. shell_quote(repo) .. " worktree add --detach "
        .. shell_quote(first) .. " HEAD")
      run_command("git -C " .. shell_quote(repo) .. " worktree add --detach "
        .. shell_quote(second) .. " HEAD")

      local sentinel = first .. "/first-attempt-verification-read"
      run_command("touch " .. shell_quote(sentinel))
      run_command("git -C " .. shell_quote(second) .. " reset --hard HEAD")
      run_command("git -C " .. shell_quote(second) .. " clean -fd")

      t.is_true(first ~= second)
      t.is_true(path_exists(sentinel), "second attempt disturbed the first attempt worktree")
    end)
    remove_fixture(root)
    if not ok then error(err) end
  end,
}
