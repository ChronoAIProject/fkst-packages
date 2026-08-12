local h = require("tests.devloop_helpers")
local devloop_base = require("devloop.base")
local harvest = require("departments.implement.harvest")
local t = h.t

local PROPOSAL_ID = "github-devloop/issue/owner/repo/42"
local LOCK_KEY = "github-devloop/transition/owner/repo/issue/42/base-probe"

local function completed_probe(path)
  return {
    status = "completed",
    exit = 0,
    head_readback = "abc123",
    result = { kind = "PASS", reason = "producer-declared" },
    detail = "",
    worktree = path,
  }
end

local function runtime_generation(root, active_paths, cleaned_paths, run)
  local locked = false
  return {
    with_lock = function(key, fn)
      t.eq(key, LOCK_KEY)
      t.eq(locked, false)
      locked = true
      local ok, value = pcall(fn)
      locked = false
      if not ok then error(value) end
      return value
    end,
    exec = function(request)
      if request.cmd == devloop_base.read_runtime_root_cmd() then
        return { stdout = root, stderr = "", exit_code = 0 }
      end
      t.is_true(request.cmd:find("mkdir -p", 1, true) ~= nil)
      return { stdout = "", stderr = "", exit_code = 0 }
    end,
    run = run,
    clean = function(path)
      cleaned_paths[#cleaned_paths + 1] = path
      t.eq(active_paths[path], nil, "one runtime generation must not clean another generation's active probe")
      return true, ""
    end,
  }
end

return {
  test_runtime_generations_own_distinct_probe_worktrees = function()
    local active_paths = {}
    local cleaned_paths = {}
    local first_path
    local second_path
    local second_runtime = runtime_generation(
      "/tmp/fkst-runtime.2",
      active_paths,
      cleaned_paths,
      function(path)
        second_path = path
        return completed_probe(path)
      end
    )
    local first_runtime = runtime_generation(
      "/tmp/fkst-runtime.1",
      active_paths,
      cleaned_paths,
      function(path)
        first_path = path
        active_paths[path] = true
        local second = harvest.base_local_iteration_probe(PROPOSAL_ID, "abc123", second_runtime)
        active_paths[path] = nil
        t.eq(second.status, "completed")
        return completed_probe(path)
      end
    )

    local first = harvest.base_local_iteration_probe(PROPOSAL_ID, "abc123", first_runtime)

    t.eq(first.status, "completed")
    t.is_true(first_path:find("/tmp/fkst-runtime.1/judgment-worktrees/", 1, true) == 1)
    t.is_true(second_path:find("/tmp/fkst-runtime.2/judgment-worktrees/", 1, true) == 1)
    t.is_true(first_path ~= second_path)
    t.eq(cleaned_paths[1], first_path)
    t.eq(cleaned_paths[2], second_path)
    t.eq(cleaned_paths[3], second_path)
    t.eq(cleaned_paths[4], first_path)
  end,

  test_runtime_root_read_failure_precedes_probe_mutation = function()
    local clean_calls = 0
    local run_calls = 0
    local result = harvest.base_local_iteration_probe(PROPOSAL_ID, "abc123", {
      with_lock = function(key, fn)
        t.eq(key, LOCK_KEY)
        return fn()
      end,
      exec = function(request)
        t.eq(request.cmd, devloop_base.read_runtime_root_cmd())
        return { stdout = "", stderr = "runtime root unavailable", exit_code = 1 }
      end,
      clean = function()
        clean_calls = clean_calls + 1
        return true, ""
      end,
      run = function()
        run_calls = run_calls + 1
        return completed_probe("unexpected")
      end,
    })

    t.eq(result.status, "setup-failed")
    t.eq(result.detail, "runtime root unavailable")
    t.eq(clean_calls, 0)
    t.eq(run_calls, 0)
  end,
}
