local gh = require("std.github")

return {
  test_exec_classifies_rate_limit = function()
    local handle = gh.new(function(_opts)
      return { stdout = "", stderr = "API rate limit exceeded for user", exit_code = 1 }
    end)
    local ok, err = pcall(function()
      return handle._exec("gh api x", 10, "ctx")
    end)
    assert(ok == false)
    assert(err.class == "gh-rate-limited", "rate-limit stderr must classify as gh-rate-limited")
    assert(err.retryable == true)
  end,

  -- Regression: GitHub's GraphQL rate-limit form is "API rate limit ALREADY
  -- exceeded for user ID N" (observed in production). The old "...exceeded"
  -- contiguous needle missed it (the interposed "already" breaks the match),
  -- so the dominant real rate-limit was misclassified non-retryable. Deliver
  -- the production form, not the form that happened to match the buggy needle.
  test_exec_classifies_graphql_already_exceeded_rate_limit = function()
    local handle = gh.new(function(_opts)
      return {
        stdout = "",
        stderr = "GraphQL: API rate limit already exceeded for user ID 1593871 (createCommitOnBranch)",
        exit_code = 1,
      }
    end)
    local ok, err = pcall(function()
      return handle._exec("gh api graphql", 10, "ctx")
    end)
    assert(ok == false)
    assert(err.class == "gh-rate-limited", "GraphQL 'already exceeded' must classify as gh-rate-limited")
    assert(err.retryable == true, "rate-limit must be retryable, not a hard failure")
  end,

  test_exec_classifies_generic_failure = function()
    local handle = gh.new(function(_opts)
      return { stdout = "", stderr = "fatal: not found", exit_code = 1 }
    end)
    local ok, err = pcall(function()
      return handle._exec("gh api y", 10, "ctx")
    end)
    assert(ok == false)
    assert(err.class == "gh-command-failed")
  end,

  test_exec_returns_result_on_success = function()
    local handle = gh.new(function(_opts)
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end)
    local out = handle._exec("gh api z", 10, "ctx")
    assert(out.stdout == "ok")
  end,
}
