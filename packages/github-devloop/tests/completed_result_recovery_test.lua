local h = require("tests.devloop_helpers")
local recovery = require("departments.implement.attempt_execution")

local t = h.t

local function lock_fixture()
  local held = {}
  local entries = {}
  local function with_test_lock(key, fn)
    if held[key] then
      error("with_lock lock busy: " .. key)
    end
    held[key] = true
    table.insert(entries, key)
    local ok, result = pcall(fn)
    held[key] = nil
    if not ok then
      error(result, 0)
    end
    return result
  end
  return with_test_lock, function(key) return held[key] == true end, entries
end

return {
  test_same_version_recovery_is_single_flight_without_holding_transition_lock = function()
    local with_test_lock, lock_held, lock_entries = lock_fixture()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "ready/github-devloop/issue/owner/repo/42/intake/1"
    local transition_lock = "github-devloop/transition/owner/repo/issue/42"
    local recovery_lock = recovery.lock_key(proposal_id, version)
    local verification_calls = 0
    local publication_calls = 0
    local nested_ok, nested_error

    local function run_recovery()
      recovery.run({
        with_lock = with_test_lock,
        proposal_id = proposal_id,
        implementation_version = version,
        completed_result = { head_sha = string.rep("a", 40) },
        transition_lock_key = transition_lock,
        admit = function()
          t.is_true(lock_held(recovery_lock))
          t.is_true(lock_held(transition_lock))
          return { current = "current" }
        end,
        prepare = function(admission)
          t.eq(admission.current, "current")
          t.is_true(lock_held(recovery_lock))
          t.eq(lock_held(transition_lock), false)
          return { completed_result = { head_sha = string.rep("a", 40) } }
        end,
        verify = function(prepared)
          t.eq(prepared.completed_result.head_sha, string.rep("a", 40))
          t.is_true(lock_held(recovery_lock))
          t.eq(lock_held(transition_lock), false)
          verification_calls = verification_calls + 1
          if verification_calls == 1 then
            nested_ok, nested_error = pcall(run_recovery)
          end
          return { kind = "implement-checkpoint" }
        end,
        publish = function(outcome)
          t.eq(outcome.kind, "implement-checkpoint")
          t.is_true(lock_held(recovery_lock))
          t.is_true(lock_held(transition_lock))
          publication_calls = publication_calls + 1
        end,
      })
    end

    run_recovery()

    t.eq(verification_calls, 1)
    t.eq(publication_calls, 1)
    t.eq(nested_ok, false)
    t.is_true(tostring(nested_error):find("with_lock lock busy", 1, true) ~= nil)
    t.eq(lock_entries[1], recovery_lock)
    t.eq(lock_entries[2], transition_lock)
    t.eq(lock_entries[3], transition_lock)
  end,

  test_recovery_identity_is_version_bound = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local first = recovery.lock_key(proposal_id, "ready/version/1")
    local second = recovery.lock_key(proposal_id, "ready/version/2")
    t.is_true(first ~= second)
    t.is_true(first:find("github-devloop/implement-recovery/", 1, true) == 1)
  end,

  test_fresh_attempt_and_recovery_share_version_flight = function()
    local with_test_lock, lock_held, lock_entries = lock_fixture()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "ready/version/1"
    local transition_lock = "github-devloop/transition/owner/repo/issue/42"
    local recovery_lock = recovery.lock_key(proposal_id, version)
    local nested_ok, nested_error

    local function run_recovery()
      recovery.run({
        with_lock = with_test_lock,
        proposal_id = proposal_id,
        implementation_version = version,
        completed_result = { version = version },
        transition_lock_key = transition_lock,
        admit = function() return {} end,
        prepare = function() return {} end,
        verify = function() return nil end,
        publish = function() end,
      })
    end

    recovery.run({
      with_lock = with_test_lock,
      proposal_id = proposal_id,
      implementation_version = version,
      transition_lock_key = transition_lock,
      admit = function() return {} end,
      prepare = function()
        t.is_true(lock_held(recovery_lock))
        t.is_true(lock_held(transition_lock))
        return {}
      end,
      verify = function()
        t.is_true(lock_held(recovery_lock))
        t.eq(lock_held(transition_lock), false)
        nested_ok, nested_error = pcall(run_recovery)
        return { kind = "implementing" }
      end,
      publish = function()
        t.is_true(lock_held(recovery_lock))
        t.is_true(lock_held(transition_lock))
      end,
    })
    t.eq(nested_ok, false)
    t.is_true(tostring(nested_error):find("with_lock lock busy", 1, true) ~= nil)
    t.eq(#lock_entries, 3)
    t.eq(lock_entries[1], recovery_lock)
    t.eq(lock_entries[2], transition_lock)
    t.eq(lock_entries[3], transition_lock)
  end,

  test_distinct_versions_do_not_share_a_recovery_flight = function()
    local with_test_lock = lock_fixture()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local transition_lock = "github-devloop/transition/owner/repo/issue/42"
    local verified, published = {}, {}
    local run_recovery

    run_recovery = function(version, run_nested)
      recovery.run({
        with_lock = with_test_lock,
        proposal_id = proposal_id,
        implementation_version = version,
        completed_result = { version = version },
        transition_lock_key = transition_lock,
        admit = function() return {} end,
        prepare = function() return {} end,
        verify = function()
          table.insert(verified, version)
          if run_nested then run_recovery("ready/version/2", false) end
          return { version = version }
        end,
        publish = function(outcome) table.insert(published, outcome.version) end,
      })
    end

    run_recovery("ready/version/1", true)
    t.eq(table.concat(verified, ","), "ready/version/1,ready/version/2")
    t.eq(table.concat(published, ","), "ready/version/2,ready/version/1")
  end,
}
