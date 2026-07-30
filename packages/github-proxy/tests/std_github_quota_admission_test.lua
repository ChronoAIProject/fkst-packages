local gh = require("forge.github")
local quota_admission = require("forge.github.quota_admission")
local stdout_policy = require("forge.github.stdout_policy")

local function same_argv(actual, expected)
  if type(actual) ~= "table" or #actual ~= #expected then
    return false
  end
  for index, value in ipairs(expected) do
    if actual[index] ~= value then
      return false
    end
  end
  return true
end

local function call(handle, argv)
  return pcall(function()
    return handle._exec(argv, 10, "quota admission test", stdout_policy.plain_text())
  end)
end

return {
  test_quota_decision_paces_cumulative_spend_against_the_provider_window = function()
    local fact = {
      limit = 5000,
      remaining = 4300,
      reset_at = 3600,
    }

    local deferred = quota_admission.decision(fact, 500)
    assert(deferred.kind == "defer")
    assert(deferred.retry_at == 504)
    assert(deferred.reset_at == 3600)
    assert(deferred.remaining == 4300)

    local admitted = quota_admission.decision(fact, 504)
    assert(admitted.kind == "admit")
  end,

  test_quota_decision_defers_exhaustion_exactly_to_provider_reset = function()
    local decision = quota_admission.decision({
      limit = 5000,
      remaining = 0,
      reset_at = 3600,
    }, 3599)

    assert(decision.kind == "defer")
    assert(decision.retry_at == 3600)
  end,

  test_command_resource_protects_graphql_without_suspending_rest = function()
    assert(quota_admission.command_resource({ "gh", "api", "graphql" }) == "graphql")
    assert(quota_admission.command_resource({ "gh", "issue", "view", "42" }) == "graphql")
    assert(quota_admission.command_resource({ "gh", "pr", "view", "7" }) == "graphql")
    assert(quota_admission.command_resource({ "gh", "issue", "close", "42" }) == nil)
    assert(quota_admission.command_resource({ "gh", "pr", "diff", "7" }) == nil)
    assert(quota_admission.command_resource({ "gh", "api", "repos/owner/repo/issues/42" }) == nil)
  end,

  test_adapter_defers_deterministically_and_recovers_from_provider_reset = function()
    local current = 500
    local quota = { limit = 5000, remaining = 4300, reset = 3600 }
    local quota_reads = 0
    local command_calls = 0
    local handle = gh.new(function(spec)
      if same_argv(spec.argv, { "gh", "api", "rate_limit", "--jq", ".resources.graphql" }) then
        quota_reads = quota_reads + 1
        return {
          stdout = string.format('{"limit":%d,"remaining":%d,"reset":%d}', quota.limit, quota.remaining, quota.reset),
          stderr = "",
          exit_code = 0,
        }
      end
      command_calls = command_calls + 1
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end, {
      quota_admission = true,
      now = function() return current end,
    })

    local ok, err = call(handle, { "gh", "issue", "view", "42" })
    assert(ok == false)
    assert(err.class == "gh-rate-limited")
    assert(err.retryable == true)
    assert(err.permanent == false)
    assert(err.quota_deferred == true)
    assert(err.resource == "graphql")
    assert(err.retry_at == 504)
    assert(err.reset_at == 3600)
    assert(command_calls == 0)

    current = 504
    assert(call(handle, { "gh", "issue", "view", "42" }) == true)
    assert(command_calls == 1)

    current = 3599
    quota = { limit = 5000, remaining = 0, reset = 3600 }
    local exhausted, exhausted_err = call(handle, { "gh", "api", "graphql" })
    assert(exhausted == false)
    assert(exhausted_err.retry_at == 3600)
    assert(exhausted_err.retryable == true)
    assert(exhausted_err.permanent == false)

    current = 3600
    quota = { limit = 5000, remaining = 5000, reset = 7200 }
    assert(call(handle, { "gh", "api", "graphql" }) == true)
    assert(command_calls == 2)
    assert(quota_reads == 4)
  end,

  test_missing_or_malformed_provider_facts_fail_closed_without_terminalizing = function()
    local probe_result = { stdout = "", stderr = "provider unavailable", exit_code = 1 }
    local command_calls = 0
    local handle = gh.new(function(spec)
      if same_argv(spec.argv, { "gh", "api", "rate_limit", "--jq", ".resources.graphql" }) then
        return probe_result
      end
      command_calls = command_calls + 1
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end, {
      quota_admission = true,
      now = function() return 100 end,
    })

    local available, unavailable_err = call(handle, { "gh", "pr", "view", "7" })
    assert(available == false)
    assert(unavailable_err.class == "gh-quota-facts-unavailable")
    assert(unavailable_err.retryable == true)
    assert(unavailable_err.permanent == false)
    assert(command_calls == 0)

    probe_result = { stdout = "not-json", stderr = "", exit_code = 0 }
    local valid, invalid_err = call(handle, { "gh", "pr", "view", "7" })
    assert(valid == false)
    assert(invalid_err.class == "gh-quota-facts-invalid")
    assert(invalid_err.retryable == true)
    assert(invalid_err.permanent == false)
    assert(command_calls == 0)
  end,
}
