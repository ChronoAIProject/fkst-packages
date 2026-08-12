local h = require("tests.devloop_helpers")
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

return {
  test_same_attempt_overlap_cannot_clean_the_active_probe = function()
    local candidate = "/tmp/fkst-packages-test/github-devloop/worktrees/candidate"
    local probe_path = candidate .. "-base-probe"
    local trace = {}
    local active = false
    local locked = false
    local runtime = {}

    runtime.with_lock = function(key, fn)
      t.eq(key, LOCK_KEY)
      if locked then
        trace[#trace + 1] = "defer"
        error("with_lock lock busy: " .. key)
      end
      locked = true
      trace[#trace + 1] = "acquire"
      local ok, value = pcall(fn)
      locked = false
      trace[#trace + 1] = "release"
      if not ok then error(value) end
      return value
    end
    runtime.exec = function(request)
      t.is_true(request.cmd:find("mkdir -p", 1, true) ~= nil)
      return { stdout = "", stderr = "", exit_code = 0 }
    end
    runtime.run = function(path)
      t.eq(path, probe_path)
      active = true
      trace[#trace + 1] = "test-start"
      local ok, err = pcall(function()
        harvest.base_local_iteration_probe(PROPOSAL_ID, candidate, "abc123", runtime)
      end)
      t.eq(ok, false)
      t.is_true(tostring(err):find("with_lock lock busy: " .. LOCK_KEY, 1, true) ~= nil)
      t.eq(active, true)
      trace[#trace + 1] = "test-complete"
      return completed_probe(path)
    end
    runtime.clean = function(path)
      t.eq(path, probe_path)
      trace[#trace + 1] = active and "cleanup" or "preclean"
      active = false
      return true, ""
    end

    local observation = harvest.base_local_iteration_probe(PROPOSAL_ID, candidate, "abc123", runtime)

    t.eq(observation.worktree, probe_path)
    t.eq(table.concat(trace, "\n"), table.concat({
      "acquire", "preclean", "test-start", "defer", "test-complete", "cleanup", "release",
    }, "\n"))
  end,
}
