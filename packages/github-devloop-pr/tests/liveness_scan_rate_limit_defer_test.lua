local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local h = require("tests.devloop_helpers")
local support = require("devloop.commands.support")
local rate_limit_fixture = require("testkit_internal.liveness_scan_rate_limit_fixture")

local t = h.t
local core = h.core
local department = require("departments.liveness_scan.main")

return {
  test_liveness_scan_declares_retry_policy_for_durable_failure_surface = function()
    t.is_true(type(department.spec.retry) == "table")
    t.eq(department.spec.retry.max_attempts, 12)
    t.eq(department.spec.retry.base, "5s")
    t.eq(department.spec.retry.cap, "30s")
  end,

  test_gh_result_preserves_adapter_classification_on_command_result = function()
    local command_result = {
      stdout = "",
      stderr = "gh: API rate limit exceeded (HTTP 403)",
      exit_code = 1,
    }
    local projected = support.gh_result(function()
      error({
        class = "gh-rate-limited",
        retryable = true,
        permanent = false,
        result = command_result,
      })
    end)

    t.is_true(projected == command_result)
    t.eq(projected.class, "gh-rate-limited")
    t.eq(projected.error_class, "gh-rate-limited")
    t.eq(projected.retryable, true)
    t.eq(projected.permanent, false)
  end,

  test_liveness_scan_rate_limit_defers_but_unknown_list_failure_still_raises = function()
    rate_limit_fixture.assert_behavior({
      t = t,
      department = department,
      devloop_base = devloop_base,
      devloop_logging = devloop_logging,
      queue = "github-devloop-pr.devloop_liveness_tick",
      list_command = core.gh_pr_list_observe_cmd,
      unknown_error = "liveness-scan-pr-list-failed",
    })
  end,
}
