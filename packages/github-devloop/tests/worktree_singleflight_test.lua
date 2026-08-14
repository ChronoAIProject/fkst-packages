local singleflight_module = require("departments.implement.worktree_singleflight")

local t = fkst.test

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function command_output(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok, _, status = handle:close()
  return output, ok ~= false and ok ~= nil, tonumber(status) or (ok and 0 or 1)
end

local function direct_exec(spec)
  local command = spec.cmd
  for name, value in pairs(spec.env or {}) do
    command = name .. "=" .. shell_quote(value) .. " " .. command
  end
  local output, ok, status = command_output(command)
  return {
    stdout = ok and output or "",
    stderr = ok and "" or output,
    exit_code = status,
  }
end

local function temporary_root()
  local root, ok = command_output("mktemp -d "
    .. shell_quote("/tmp/fkst-implementation-worktree-singleflight.XXXXXX"))
  if not ok then
    error("github-devloop-test: worktree single-flight fixture creation failed: " .. tostring(root))
  end
  return root:gsub("%s+$", "")
end

local function clean_fixture(root, worktree)
  os.remove(singleflight_module.lock_path(worktree))
  local ok, _, status = os.execute("rmdir " .. shell_quote(root))
  if ok ~= true and ok ~= 0 then
    error("github-devloop-test: worktree single-flight fixture cleanup failed with status "
      .. tostring(status))
  end
end

local function assert_error_contains(fn, expected)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(expected, 1, true) ~= nil,
    "expected error containing " .. expected .. ", got: " .. tostring(err))
end

return {
  test_real_lock_is_single_flight_and_reacquires_after_release = function()
    local root = temporary_root()
    local worktree = root .. "/candidate"
    local singleflight = singleflight_module.make({ exec = direct_exec })
    local token = singleflight.acquire(worktree)
    local busy_token = singleflight.acquire(worktree)

    t.is_true(token ~= nil)
    t.is_nil(busy_token)

    singleflight.release(worktree, token)
    local next_token = singleflight.acquire(worktree)
    t.is_true(next_token ~= nil and next_token ~= token)
    singleflight.release(worktree, next_token)
    clean_fixture(root, worktree)
  end,

  test_callback_failure_releases_the_lock = function()
    local root = temporary_root()
    local worktree = root .. "/candidate"
    local singleflight = singleflight_module.make({ exec = direct_exec })

    assert_error_contains(function()
      singleflight.with_lock(worktree, function()
        error("forced callback failure")
      end)
    end, "forced callback failure")

    local token = singleflight.acquire(worktree)
    t.is_true(token ~= nil)
    singleflight.release(worktree, token)
    clean_fixture(root, worktree)
  end,

  test_rejected_token_does_not_release_the_lock = function()
    local root = temporary_root()
    local worktree = root .. "/candidate"
    local singleflight = singleflight_module.make({ exec = direct_exec })
    local token = singleflight.acquire(worktree)

    assert_error_contains(function()
      singleflight.release(worktree, string.rep("0", #token))
    end, "worktree single-flight release was rejected")
    t.is_nil(singleflight.acquire(worktree))

    singleflight.release(worktree, token)
    clean_fixture(root, worktree)
  end,

  test_owner_process_death_releases_the_kernel_lock = function()
    local root = temporary_root()
    local worktree = root .. "/candidate"
    local singleflight = singleflight_module.make({ exec = direct_exec })
    local owner_output, owner_ok = command_output("sleep 30 </dev/null >/dev/null 2>&1 & echo $!")
    t.is_true(owner_ok)
    local owner_pid = assert(owner_output:match("^(%d+)%s*$"))
    local token = singleflight_module._acquire_for_owner(worktree, owner_pid, direct_exec)

    t.is_true(token ~= nil)
    t.is_nil(singleflight.acquire(worktree))
    local killed = os.execute("kill " .. owner_pid)
    t.is_true(killed == true or killed == 0)

    local replacement
    for _ = 1, 50 do
      replacement = singleflight.acquire(worktree)
      if replacement ~= nil then break end
      os.execute("sleep 0.02")
    end
    t.is_true(replacement ~= nil, "owner death did not release the kernel lock")
    singleflight.release(worktree, replacement)
    clean_fixture(root, worktree)
  end,

  test_malformed_and_failed_helper_results_fail_closed = function()
    local malformed = singleflight_module.make({ exec = function()
      return { stdout = "not-a-singleflight-result\n", stderr = "", exit_code = 0 }
    end })
    assert_error_contains(function()
      malformed.acquire("/tmp/fkst-worktree-singleflight-malformed")
    end, "helper returned a malformed result")

    local failed = singleflight_module.make({ exec = function()
      return { stdout = "", stderr = "watcher unavailable", exit_code = 1 }
    end })
    assert_error_contains(function()
      failed.acquire("/tmp/fkst-worktree-singleflight-failed")
    end, "watcher unavailable")
  end,

  test_non_absolute_and_multiline_worktree_paths_fail_closed = function()
    assert_error_contains(function()
      singleflight_module.lock_path("relative/worktree")
    end, "worktree path must be absolute")
    assert_error_contains(function()
      singleflight_module.lock_path("/tmp/worktree\nother")
    end, "worktree path must be absolute")
  end,
}
