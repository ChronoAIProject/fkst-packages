local lease_module = require("departments.implement.worktree_lease")

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
  local output, ok, status = command_output(spec.cmd)
  return {
    stdout = ok and output or "",
    stderr = ok and "" or output,
    exit_code = status,
  }
end

local function temporary_root()
  local root, ok = command_output("mktemp -d "
    .. shell_quote("/tmp/fkst-implementation-worktree-lease.XXXXXX"))
  if not ok then
    error("github-devloop-test: worktree lease fixture creation failed: " .. tostring(root))
  end
  return root:gsub("%s+$", "")
end

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local function write_file(path, body)
  local handle = assert(io.open(path, "w"))
  handle:write(body)
  handle:close()
end

local function clean_fixture(root, worktree)
  os.remove(lease_module.lease_path(worktree) .. ".owner")
  os.remove(lease_module.lease_path(worktree) .. ".lock")
  local ok, _, status = os.execute("rmdir " .. shell_quote(root))
  if ok ~= true and ok ~= 0 then
    error("github-devloop-test: worktree lease fixture cleanup failed with status "
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
  test_real_lease_is_single_flight_and_reacquires_after_release = function()
    local root = temporary_root()
    local worktree = root .. "/candidate"
    local lease = lease_module.make({ exec = direct_exec })
    local token = lease.acquire(worktree)
    local busy_token, owner_pid = lease.acquire(worktree)

    t.is_true(token ~= nil)
    t.is_nil(busy_token)
    t.is_true(type(owner_pid) == "number" and owner_pid > 0)

    lease.release(worktree, token)
    local next_token = lease.acquire(worktree)
    t.is_true(next_token ~= nil and next_token ~= token)
    lease.release(worktree, next_token)
    clean_fixture(root, worktree)
  end,

  test_pid_start_identity_mismatch_reclaims_stale_owner = function()
    local root = temporary_root()
    local worktree = root .. "/candidate"
    local path = lease_module.lease_path(worktree)
    local lease = lease_module.make({ exec = direct_exec })
    local first_token = lease.acquire(worktree)
    local owner = json.decode(read_file(path .. ".owner"))
    write_file(path .. ".owner", '{"pid":' .. tostring(owner.pid)
      .. ',"schema":"FKST_IMPLEMENTATION_WORKTREE_LEASE:v1"'
      .. ',"start_identity":"stale-process-incarnation","token":"stale-token"}\n')

    local replacement_token = lease.acquire(worktree)

    t.is_true(replacement_token ~= nil and replacement_token ~= first_token)
    lease.release(worktree, replacement_token)
    clean_fixture(root, worktree)
  end,

  test_release_requires_the_current_owner_token = function()
    local root = temporary_root()
    local worktree = root .. "/candidate"
    local lease = lease_module.make({ exec = direct_exec })
    local token = lease.acquire(worktree)

    assert_error_contains(function()
      lease.release(worktree, "different-token")
    end, "release token does not own the current lease")

    local busy_token = lease.acquire(worktree)
    t.is_nil(busy_token)
    lease.release(worktree, token)
    clean_fixture(root, worktree)
  end,

  test_callback_failure_releases_the_lease = function()
    local root = temporary_root()
    local worktree = root .. "/candidate"
    local lease = lease_module.make({ exec = direct_exec })

    assert_error_contains(function()
      lease.with_lease(worktree, function()
        error("forced callback failure")
      end)
    end, "forced callback failure")

    local token = lease.acquire(worktree)
    t.is_true(token ~= nil)
    lease.release(worktree, token)
    clean_fixture(root, worktree)
  end,

  test_malformed_and_failed_helper_results_fail_closed = function()
    local malformed = lease_module.make({ exec = function()
      return { stdout = "not-a-lease-result\n", stderr = "", exit_code = 0 }
    end })
    assert_error_contains(function()
      malformed.acquire("/tmp/fkst-worktree-lease-malformed")
    end, "helper returned a malformed result")

    local failed = lease_module.make({ exec = function()
      return { stdout = "", stderr = "identity unreadable", exit_code = 1 }
    end })
    assert_error_contains(function()
      failed.acquire("/tmp/fkst-worktree-lease-failed")
    end, "identity unreadable")
  end,
}
