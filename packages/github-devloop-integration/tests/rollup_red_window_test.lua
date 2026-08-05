local h = require("tests.devloop_helpers")

local core = h.core
local t = h.t

local function exec_returning(value)
  return function(_command)
    return { stdout = value, stderr = "", exit_code = 0 }
  end
end

local function red_pr(head_sha, failing_head_sha)
  return {
    head_sha = head_sha,
    status_check_rollup = {
      {
        name = "test",
        state = "COMPLETED",
        conclusion = "FAILURE",
        headSha = failing_head_sha,
      },
    },
  }
end

return {
  -- Regression guard for the latent bug fixed alongside the _trim decouple: the old
  -- ambient M._trim returned two values (the trimmed string plus the chained gsub's
  -- substitution count), so `tonumber(M._trim(raw))` passed that count (0 or 1) as
  -- tonumber's base and raised "base out of range" for ANY set value — the custom red
  -- window never parsed. Resolving to contract.strings.trim (single value) fixes it.
  test_rollup_red_window_minutes_parses_a_set_value = function()
    t.eq(core.rollup_red_window_minutes(exec_returning("30")), 30)
  end,

  test_rollup_red_window_minutes_trims_surrounding_whitespace = function()
    t.eq(core.rollup_red_window_minutes(exec_returning("  45  ")), 45)
  end,

  test_rollup_red_window_minutes_rejects_non_numeric = function()
    t.raises(function()
      core.rollup_red_window_minutes(exec_returning("abc"))
    end)
  end,

  test_rollup_red_window_minutes_rejects_out_of_range = function()
    t.raises(function()
      core.rollup_red_window_minutes(exec_returning("5000"))
    end)
  end,

  test_rollup_health_dedup_key_is_head_scoped_and_requires_a_valid_head = function()
    local key = core.rollup_health_dedup_key("owner/repo", "test: COMPLETED/FAILURE", "aaaa1111")
    t.eq(key, core.rollup_health_dedup_key("owner/repo", "test: COMPLETED/FAILURE", "aaaa1111"))
    t.is_true(key ~= core.rollup_health_dedup_key("owner/repo", "test: COMPLETED/FAILURE", "bbbb2222"))
    t.raises(function()
      core.rollup_health_dedup_key("owner/repo", "test: COMPLETED/FAILURE", nil)
    end)
    t.raises(function()
      core.rollup_health_dedup_key("owner/repo", "test: COMPLETED/FAILURE", "not-a-sha")
    end)
  end,

  test_rollup_health_noops_on_stale_red_check_head = function()
    local result = core.observe_rollup_health(
      "owner/repo",
      "dev",
      "integration/dev",
      red_pr("aaaa1111", "bbbb2222"),
      now(),
      30
    )

    t.eq(result.action, "no-op")
    t.eq(result.reason, "stale-red-check-head")
  end,

  test_rollup_health_keeps_unknown_red_check_head_distinct = function()
    local result = core.observe_rollup_health(
      "owner/repo",
      "dev",
      "integration/dev",
      red_pr("aaaa1111", nil),
      now(),
      30
    )

    t.eq(result.action, "no-op")
    t.eq(result.reason, "red-check-head-unknown")
  end,
}
