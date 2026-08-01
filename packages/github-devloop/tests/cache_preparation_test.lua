local cache_preparation = require("departments.implement.cache_preparation")
local t = fkst.test

local function captures()
  local calls = {}
  local function exec(opts)
    calls[#calls + 1] = opts
    return { stdout = "cache ready\n", stderr = "", exit_code = 0 }
  end
  return calls, exec
end

return {
  test_cache_preparation_skips_when_command_is_unset = function()
    local called = false
    local ran = cache_preparation.run("/tmp/implementation-worktree", {
      command = function() return nil end,
      exec = function()
        called = true
        return { stdout = "", stderr = "", exit_code = 0 }
      end,
    })

    t.eq(ran, false)
    t.eq(called, false)
  end,

  test_cache_preparation_runs_repository_command_in_worktree_with_fixed_bound = function()
    local calls, exec = captures()
    local ran = cache_preparation.run("/tmp/implementation-worktree", {
      command = function() return "make prepare-cache" end,
      exec = exec,
    })

    t.eq(ran, true)
    t.eq(#calls, 1)
    t.eq(calls[1].cmd, "make prepare-cache")
    t.eq(calls[1].cwd, "/tmp/implementation-worktree")
    t.eq(calls[1].timeout, 600)
  end,

  test_cache_preparation_runs_again_so_repository_cache_can_be_reused = function()
    local calls, exec = captures()
    local deps = {
      command = function() return "make prepare-cache" end,
      exec = exec,
    }

    t.eq(cache_preparation.run("/tmp/implementation-worktree", deps), true)
    t.eq(cache_preparation.run("/tmp/implementation-worktree", deps), true)

    t.eq(#calls, 2)
    t.eq(calls[1].cwd, calls[2].cwd)
  end,

  test_cache_preparation_propagates_command_failure = function()
    local ok, err = pcall(function()
      cache_preparation.run("/tmp/implementation-worktree", {
        command = function() return "make prepare-cache" end,
        exec = function()
          return { stdout = "", stderr = "cache seed failed", exit_code = 7 }
        end,
      })
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("cache-preparation-failed", 1, true) ~= nil)
    t.is_true(tostring(err):find("cache seed failed", 1, true) ~= nil)
  end,
}
