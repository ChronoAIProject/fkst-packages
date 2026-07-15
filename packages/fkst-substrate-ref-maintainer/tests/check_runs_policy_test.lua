local t = fkst.test
local check_runs = require("forge.github.check_runs")

local function completed(name, conclusion)
  return {
    name = name,
    status = "completed",
    conclusion = conclusion,
  }
end

return {
  test_verify_policy_accepts_successful_substrate_run_set = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("verify", "success"),
      completed("coverage", "success"),
    }, { "verify" })

    t.eq(green, true)
    t.eq(reason, "rollup-green")
  end,

  test_missing_verify_policy_holds = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("coverage", "success"),
    }, { "verify" })

    t.eq(green, false)
    t.eq(reason, "missing-status-rollup")
  end,

  test_red_verify_policy_holds = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("verify", "failure"),
    }, { "verify" })

    t.eq(green, false)
    t.eq(reason, "rollup-red")
  end,

  test_completed_optional_failure_still_holds = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("verify", "success"),
      completed("coverage", "failure"),
    }, { "verify" })

    t.eq(green, false)
    t.eq(reason, "rollup-red")
  end,

  test_test_policy_still_requires_test = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("verify", "success"),
    }, { "test" })

    t.eq(green, false)
    t.eq(reason, "missing-status-rollup")
  end,

  test_nil_required_policy_holds = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("test", "success"),
    }, nil)

    t.eq(green, false)
    t.eq(reason, "missing-status-rollup")
  end,

  test_empty_required_policy_holds = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("test", "success"),
    }, {})

    t.eq(green, false)
    t.eq(reason, "missing-status-rollup")
  end,
}
