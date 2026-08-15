local h = require("tests.devloop_helpers")
local recovery = require("departments.implement.completed_result_recovery")

local t = h.t

local function lock_fixture()
  local held = false
  local entries = 0
  local function with_test_lock(key, fn)
    t.eq(key, "github-devloop/transition/owner/repo/issue/42")
    if held then
      error("with_lock lock busy: " .. key)
    end
    held = true
    entries = entries + 1
    local ok, result = pcall(fn)
    held = false
    if not ok then
      error(result, 0)
    end
    return result
  end
  return with_test_lock, function() return held end, function() return entries end
end

return {
  test_completed_result_verification_and_publication_are_single_flight = function()
    local with_test_lock, lock_held, lock_entries = lock_fixture()
    local verification_calls = 0
    local publication_calls = 0
    local nested_ok, nested_error

    local function run_recovery()
      return recovery.run(
        with_test_lock,
        "github-devloop/transition/owner/repo/issue/42",
        function()
          t.is_true(lock_held(), "completed-result preparation must hold the version lock")
          return "/tmp/implementation", "100", "implement/exec/1", nil,
            { head_sha = string.rep("a", 40) }
        end,
        function()
          t.is_true(lock_held(), "completed-result verification must hold the version lock")
          verification_calls = verification_calls + 1
          if verification_calls == 1 then
            nested_ok, nested_error = pcall(run_recovery)
          end
          t.is_true(lock_held(), "completed-result publication must use the same lock epoch")
          publication_calls = publication_calls + 1
        end)
    end

    local prepared, recovered = run_recovery()

    t.is_true(recovered)
    t.eq(prepared.completed_result.head_sha, string.rep("a", 40))
    t.eq(verification_calls, 1)
    t.eq(publication_calls, 1)
    t.eq(lock_entries(), 1)
    t.eq(nested_ok, false)
    t.is_true(tostring(nested_error):find("with_lock lock busy", 1, true) ~= nil)
  end,

  test_fresh_attempt_leaves_the_lock_before_receiver_work = function()
    local with_test_lock, lock_held, lock_entries = lock_fixture()
    local resume_calls = 0

    local prepared, recovered = recovery.run(
      with_test_lock,
      "github-devloop/transition/owner/repo/issue/42",
      function()
        t.is_true(lock_held(), "attempt preparation must hold the transition lock")
        return "/tmp/implementation", "100", "implement/exec/1", "authorization", nil
      end,
      function()
        resume_calls = resume_calls + 1
      end)

    t.eq(prepared.worktree, "/tmp/implementation")
    t.eq(recovered, false)
    t.eq(resume_calls, 0)
    t.eq(lock_entries(), 1)
    t.eq(lock_held(), false)
  end,
}
