local gh = require("forge.github")
local stdout_policy = require("forge.github.stdout_policy")

local function is_argv(argv, expected)
  if #argv ~= #expected then
    return false
  end
  for index, value in ipairs(expected) do
    if argv[index] ~= value then
      return false
    end
  end
  return true
end

local function call(handle, argv)
  return pcall(function()
    return handle._exec(argv, 10, "rate limit test", stdout_policy.plain_text())
  end)
end

return {
  test_graphql_breaker_is_shared_by_credential_and_does_not_suspend_rest = function()
    local current = 100
    local issue_calls = 0
    local reset_probes = 0
    local first = gh.new(function(spec)
      if is_argv(spec.argv, { "gh", "api", "rate_limit" }) then
        reset_probes = reset_probes + 1
        return {
          stdout = '{"resources":{"graphql":{"remaining":0,"reset":200},"core":{"remaining":4999,"reset":200}}}',
          stderr = "",
          exit_code = 0,
        }
      end
      issue_calls = issue_calls + 1
      return {
        stdout = "",
        stderr = "GraphQL: API rate limit already exceeded for user ID 1593871",
        exit_code = 1,
      }
    end, {
      credential_scope = "fkst-test-bot",
      now = function() return current end,
    })

    local ok, err = call(first, { "gh", "issue", "view", "42", "--repo", "owner/repo", "--json", "title" })
    assert(ok == false)
    assert(err.class == "gh-rate-limited")
    assert(issue_calls == 1)
    assert(reset_probes == 1)

    local second_calls = 0
    local second = gh.new(function(_spec)
      second_calls = second_calls + 1
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end, {
      credential_scope = "fkst-test-bot",
      now = function() return current end,
    })
    local blocked, blocked_err = call(second, { "gh", "pr", "view", "7", "--repo", "owner/repo", "--json", "title" })
    assert(blocked == false)
    assert(blocked_err.class == "gh-rate-limited")
    assert(blocked_err.resource == "graphql")
    assert(blocked_err.reset_at == 200)
    assert(second_calls == 0, "same-credential GraphQL consumers must share the open breaker")

    local issue_list_blocked, issue_list_err = call(second, {
      "gh", "issue", "list", "--repo", "owner/repo", "--state", "open", "--json", "number",
    })
    assert(issue_list_blocked == false)
    assert(issue_list_err.resource == "graphql")

    local pr_list_blocked, pr_list_err = call(second, {
      "gh", "pr", "list", "--repo", "owner/repo", "--state", "open", "--json", "number",
    })
    assert(pr_list_blocked == false)
    assert(pr_list_err.resource == "graphql")
    assert(second_calls == 0, "all GraphQL-backed list consumers must share the open breaker")

    local rest_ok = call(second, { "gh", "api", "repos/owner/repo/issues/42" })
    assert(rest_ok == true)
    assert(second_calls == 1, "GraphQL exhaustion must not suppress healthy REST")

    local other_scope_calls = 0
    local other_scope = gh.new(function(_spec)
      other_scope_calls = other_scope_calls + 1
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end, {
      credential_scope = "other-bot",
      now = function() return current end,
    })
    assert(call(other_scope, { "gh", "api", "graphql", "-f", "query=query { viewer { login } }" }) == true)
    assert(other_scope_calls == 1, "breaker state must not cross credential identities")

    current = 200
    assert(call(second, { "gh", "api", "graphql", "-f", "query=query { viewer { login } }" }) == true)
    assert(second_calls == 2, "the authoritative reset instant must close the breaker")
  end,

  test_breaker_does_not_invent_a_reset_when_provider_fact_is_missing = function()
    local current = 300
    local command_calls = 0
    local reset_probes = 0
    local handle = gh.new(function(spec)
      if is_argv(spec.argv, { "gh", "api", "rate_limit" }) then
        reset_probes = reset_probes + 1
        return {
          stdout = '{"resources":{"graphql":{"remaining":0}}}',
          stderr = "",
          exit_code = 0,
        }
      end
      command_calls = command_calls + 1
      if command_calls == 1 then
        return { stdout = "", stderr = "GraphQL: API rate limit exceeded", exit_code = 1 }
      end
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end, {
      credential_scope = "no-reset-bot",
      now = function() return current end,
    })

    assert(call(handle, { "gh", "api", "graphql", "-f", "query=query { viewer { login } }" }) == false)
    assert(call(handle, { "gh", "api", "graphql", "-f", "query=query { viewer { login } }" }) == true)
    assert(command_calls == 2, "missing reset evidence must not create an arbitrary suspension")
    assert(reset_probes == 1)
  end,
}
