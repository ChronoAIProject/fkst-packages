local t = fkst.test
local check_runs = require("forge.github.check_runs")

local function completed(name, conclusion, app_slug)
  return {
    name = name,
    status = "completed",
    conclusion = conclusion,
    app = app_slug and { slug = app_slug } or nil,
  }
end

return {
  test_verify_policy_accepts_successful_substrate_run_set = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("verify", "success", "github-actions"),
      completed("coverage", "success"),
    }, { "verify" }, "github-actions")

    t.eq(green, true)
    t.eq(reason, "rollup-green")
  end,

  test_verify_policy_rejects_same_name_from_untrusted_producer = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("verify", "success", "untrusted-check-writer"),
      completed("coverage", "success"),
    }, { "verify" }, "github-actions")

    t.eq(green, false)
    t.eq(reason, "missing-status-rollup")
  end,

  test_missing_verify_policy_holds = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("coverage", "success"),
    }, { "verify" }, "github-actions")

    t.eq(green, false)
    t.eq(reason, "missing-status-rollup")
  end,

  test_red_verify_policy_holds = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("verify", "failure", "github-actions"),
    }, { "verify" }, "github-actions")

    t.eq(green, false)
    t.eq(reason, "rollup-red")
  end,

  test_completed_optional_failure_still_holds = function()
    local green, reason = check_runs.commit_check_runs_green({
      completed("verify", "success", "github-actions"),
      completed("coverage", "failure"),
    }, { "verify" }, "github-actions")

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
