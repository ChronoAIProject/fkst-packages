local gh = require("std.github")
local git = require("std.git")

local function assert_argv_equal(actual, expected, context)
  assert(type(actual) == "table", context .. " argv must be a table")
  assert(#actual == #expected, context .. " argv length mismatch")
  for index, value in ipairs(expected) do
    assert(actual[index] == value, context .. " argv[" .. tostring(index) .. "] mismatch")
  end
end

local function assert_no_shell_fields(opts, context)
  assert(opts.cmd == nil, context .. " must not pass cmd")
  assert(opts.rate_pool == nil, context .. " must not pass rate_pool")
end

local function issue_stdout()
  return [[{"number":42,"title":"Title","body":"Body","url":"https://github.com/owner/repo/issues/42","updatedAt":"2026-06-15T00:00:00Z","state":"OPEN","labels":[],"comments":[],"assignees":[],"author":{"login":"author"}}]]
end

return {
  test_exec_classifies_rate_limit = function()
    local handle = gh.new(function(_opts)
      return { stdout = "", stderr = "API rate limit exceeded for user", exit_code = 1 }
    end)
    local ok, err = pcall(function()
      return handle._exec({ "gh", "api", "x" }, 10, "ctx")
    end)
    assert(ok == false)
    assert(err.class == "gh-rate-limited", "rate-limit stderr must classify as gh-rate-limited")
    assert(err.retryable == true)
  end,

  test_exec_classifies_already_exceeded_rate_limit = function()
    -- Regression (#710 Finding 1): the dominant GitHub wording interposes
    -- "already", which a contiguous "api rate limit exceeded" needle misses,
    -- mis-classifying the most common rate-limit error as non-retryable.
    local handle = gh.new(function(_opts)
      return { stdout = "", stderr = "GraphQL: API rate limit already exceeded for user ID 1593871", exit_code = 1 }
    end)
    local ok, err = pcall(function()
      return handle._exec({ "gh", "api", "x" }, 10, "ctx")
    end)
    assert(ok == false)
    assert(err.class == "gh-rate-limited", "'already exceeded' wording must classify as gh-rate-limited")
    assert(err.retryable == true)
  end,

  test_exec_classifies_generic_failure = function()
    local handle = gh.new(function(_opts)
      return { stdout = "", stderr = "fatal: not found", exit_code = 1 }
    end)
    local ok, err = pcall(function()
      return handle._exec({ "gh", "api", "y" }, 10, "ctx")
    end)
    assert(ok == false)
    assert(err.class == "gh-command-failed")
  end,

  test_exec_returns_result_on_success = function()
    local handle = gh.new(function(_opts)
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end)
    local out = handle._exec({ "gh", "api", "z" }, 10, "ctx")
    assert(out.stdout == "ok")
  end,

  test_github_exec_uses_argv_without_shell_fields = function()
    local seen
    local handle = gh.new(function(opts)
      seen = opts
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end)

    handle._exec({ "gh", "api", "repos/owner/repo" }, 12, "ctx")

    assert_argv_equal(seen.argv, { "gh", "api", "repos/owner/repo" }, "github")
    assert(seen.timeout == 12, "timeout is forwarded")
    assert_no_shell_fields(seen, "github exec")
  end,

  test_github_exec_rejects_non_gh_program = function()
    local handle = gh.new(function(_opts)
      error("exec must not be called for adapter misuse")
    end)

    local ok, err = pcall(function()
      return handle._exec({ "git", "api", "repos/owner/repo" }, 12, "ctx")
    end)

    assert(ok == false)
    assert(err.class == "gh-adapter-misuse")
    assert(err.bad_program == "git")
    assert(tostring(err):find("git", 1, true) ~= nil, "misuse error must name the bad program")
  end,

  test_git_exec_uses_argv_without_shell_fields = function()
    local seen
    local handle = git.new(function(opts)
      seen = opts
      return { stdout = "ok", stderr = "", exit_code = 0 }
    end)

    handle._exec({ "git", "status", "--short" }, 7, "ctx")

    assert_argv_equal(seen.argv, { "git", "status", "--short" }, "git")
    assert(seen.timeout == 7, "timeout is forwarded")
    assert_no_shell_fields(seen, "git exec")
  end,

  test_git_exec_rejects_non_git_program = function()
    local handle = git.new(function(_opts)
      error("exec must not be called for adapter misuse")
    end)

    local ok, err = pcall(function()
      return handle._exec({ "gh", "status", "--short" }, 7, "ctx")
    end)

    assert(ok == false)
    assert(err.class == "git-adapter-misuse")
    assert(err.bad_program == "gh")
    assert(tostring(err):find("gh", 1, true) ~= nil, "misuse error must name the bad program")
  end,

  test_read_issue_builder_uses_gh_argv = function()
    local calls = {}
    local comments_query = table.concat({ "per", "page=100" }, "_")
    local comments_path = "repos/owner/repo/issues/42/comments?" .. comments_query
    local handle = gh.new(function(opts)
      table.insert(calls, opts)
      if opts.argv[5] == comments_path then
        return { stdout = "[]", stderr = "", exit_code = 0 }
      end
      return { stdout = issue_stdout(), stderr = "", exit_code = 0 }
    end)

    local issue = handle.read_issue({ kind = "external", ref = "owner/repo#issue/42" }, {
      force_fresh = true,
      timeout = 9,
    })

    assert(issue.number == 42, "read_issue still parses stdout")
    assert(#calls == 2, "force_fresh read_issue fetches REST issue and comments")
    assert_argv_equal(calls[1].argv, { "gh", "api", "repos/owner/repo/issues/42" }, "read_issue")
    assert_argv_equal(
      calls[2].argv,
      { "gh", "api", "--paginate", "--slurp", comments_path },
      "read_issue comments"
    )
    for index, call in ipairs(calls) do
      assert(call.timeout == 9, "read_issue forwards timeout for call " .. tostring(index))
      assert_no_shell_fields(call, "read_issue")
    end
  end,

  test_github_proxy_core_methods_use_gh_argv = function()
    local calls = {}
    local handle = gh.new(function(opts)
      table.insert(calls, opts)
      if opts.argv[2] == "label" and opts.argv[3] == "list" then
        return { stdout = '[{"name":"fkst-dev:ready"}]', stderr = "", exit_code = 0 }
      end
      if opts.argv[2] == "pr" and opts.argv[3] == "create" then
        return { stdout = "https://github.com/owner/repo/pull/8\n", stderr = "", exit_code = 0 }
      end
      return { stdout = "[]", stderr = "", exit_code = 0 }
    end)

    handle.list_open_issues("owner/repo", 11)
    handle.list_open_prs("owner/repo", 12)
    handle.find_open_pr_for_head("owner/repo", "devloop-owner-repo-42-01HY", "dev", 13)
    handle.create_pr("owner/repo", "devloop-owner-repo-42-01HY", "dev", "Fix title", "/tmp/body.md", 14)
    handle.view_pr_rest("owner/repo", 7, 15)
    handle.list_repo_labels("owner/repo", 16)
    handle.create_label("owner/repo", "fkst-dev:ready", "0E8A16", 17)
    handle.edit_issue_labels("owner/repo", 42, { "fkst-dev:ready" }, { "fkst-dev:thinking" }, 18)
    handle.edit_pr_labels("owner/repo", 7, { "review" }, { "stale" }, 19)
    handle.view_issue_comments("owner/repo", 42, 20)
    handle.comment_issue("owner/repo", 42, "/tmp/issue-body.md", 21)
    handle.view_pr_comments("owner/repo", 7, 22)
    handle.comment_pr("owner/repo", 7, "/tmp/pr-body.md", 23)

    assert_argv_equal(
      calls[1].argv,
      { "gh", "api", "--paginate", "--slurp", "repos/owner/repo/issues?state=open&per_page=100" },
      "list_open_issues"
    )
    assert_argv_equal(
      calls[2].argv,
      { "gh", "api", "--paginate", "--slurp", "repos/owner/repo/pulls?state=open&per_page=100" },
      "list_open_prs"
    )
    assert_argv_equal(
      calls[3].argv,
      { "gh", "api", "--paginate", "--slurp", "repos/owner/repo/pulls?state=open&head=owner%3Adevloop-owner-repo-42-01HY&per_page=100&base=dev" },
      "find_open_pr_for_head"
    )
    assert_argv_equal(
      calls[4].argv,
      { "gh", "pr", "create", "--repo", "owner/repo", "--head", "devloop-owner-repo-42-01HY", "--base", "dev", "--title", "Fix title", "--body-file", "/tmp/body.md" },
      "create_pr"
    )
    assert_argv_equal(calls[5].argv, { "gh", "api", "repos/owner/repo/pulls/7" }, "view_pr_rest")
    assert_argv_equal(
      calls[6].argv,
      { "gh", "label", "list", "--repo", "owner/repo", "--limit", "1000", "--json", "name" },
      "list_repo_labels"
    )
    assert_argv_equal(
      calls[7].argv,
      { "gh", "label", "create", "fkst-dev:ready", "--repo", "owner/repo", "--color", "0E8A16" },
      "create_label"
    )
    assert_argv_equal(
      calls[8].argv,
      { "gh", "issue", "edit", "42", "--repo", "owner/repo", "--add-label", "fkst-dev:ready", "--remove-label", "fkst-dev:thinking" },
      "edit_issue_labels"
    )
    assert_argv_equal(
      calls[9].argv,
      { "gh", "pr", "edit", "7", "--repo", "owner/repo", "--add-label", "review", "--remove-label", "stale" },
      "edit_pr_labels"
    )
    assert_argv_equal(
      calls[10].argv,
      { "gh", "api", "--paginate", "--slurp", "repos/owner/repo/issues/42/comments?per_page=100" },
      "view_issue_comments"
    )
    assert_argv_equal(
      calls[11].argv,
      { "gh", "issue", "comment", "42", "--repo", "owner/repo", "--body-file", "/tmp/issue-body.md" },
      "comment_issue"
    )
    assert_argv_equal(
      calls[12].argv,
      { "gh", "api", "--paginate", "--slurp", "repos/owner/repo/issues/7/comments?per_page=100" },
      "view_pr_comments"
    )
    assert_argv_equal(
      calls[13].argv,
      { "gh", "pr", "comment", "7", "--repo", "owner/repo", "--body-file", "/tmp/pr-body.md" },
      "comment_pr"
    )
    for index, call in ipairs(calls) do
      assert(call.timeout == index + 10, "timeout forwarded for call " .. tostring(index))
      assert_no_shell_fields(call, "github proxy method " .. tostring(index))
    end
  end,

  test_github_proxy_core_methods_validate_refs_before_exec = function()
    local handle = gh.new(function(_opts)
      error("exec must not be called for invalid adapter input")
    end)

    assert(not pcall(handle.find_open_pr_for_head, "owner/repo", "bad branch", nil, 30))
    assert(not pcall(handle.create_pr, "owner/repo", "bad branch", nil, "title", "/tmp/body.md", 30))
  end,

  test_github_proxy_git_methods_use_git_argv = function()
    local calls = {}
    local handle = git.new(function(opts)
      table.insert(calls, opts)
      return { stdout = "abcdef refs/heads/devloop-owner-repo-42-01HY\n", stderr = "", exit_code = 0 }
    end)

    handle.push_branch("devloop-owner-repo-42-01HY", 21)
    handle.show_ref_branch("devloop-owner-repo-42-01HY", 22)
    handle.is_ancestor("abcdef", "123456", 23)

    assert_argv_equal(calls[1].argv, { "git", "push", "-u", "origin", "devloop-owner-repo-42-01HY" }, "push_branch")
    assert_argv_equal(calls[2].argv, { "git", "show-ref", "--verify", "refs/heads/devloop-owner-repo-42-01HY" }, "show_ref_branch")
    assert_argv_equal(calls[3].argv, { "git", "merge-base", "--is-ancestor", "abcdef", "123456" }, "is_ancestor")
    for index, call in ipairs(calls) do
      assert(call.timeout == index + 20, "timeout forwarded for git call " .. tostring(index))
      assert_no_shell_fields(call, "git proxy method " .. tostring(index))
    end
  end,

  test_github_proxy_git_methods_validate_refs_before_exec = function()
    local handle = git.new(function(_opts)
      error("exec must not be called for invalid adapter input")
    end)

    assert(not pcall(handle.push_branch, "bad branch", 30))
    assert(not pcall(handle.show_ref_branch, "bad branch", 30))
    assert(not pcall(handle.is_ancestor, "not-a-sha", "123456", 30))
  end,
}
