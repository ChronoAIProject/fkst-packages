local h = require("tests.devloop_core_helpers")
local author_policy = require("testkit_internal.github_author_policy")
local parsers_issue = require("devloop.parsers.issue")
local seam = require("tests.entity_read_mock_helpers")

local core = h.core
local t = h.t

local state_selector = "title,createdAt,updatedAt,labels,state,comments,assignees,author"

local function mock_author_policy()
  return author_policy.mock_env(t, nil, {
    configure_trusted_bot_login = h.mock_author_policy_configure,
  })
end

local function mock_graphql_failure(repo, number, stderr)
  t.mock_command(core.gh_issue_view_state_cmd(repo, number), {
    stdout = "",
    stderr = stderr,
    exit_code = 1,
  })
end

local function issue_rest_command(repo, number)
  return "gh api repos/" .. tostring(repo) .. "/issues/" .. tostring(number)
end

local function comments_rest_command(repo, number)
  return "gh api --paginate --slurp '"
    .. "repos/" .. tostring(repo) .. "/issues/" .. tostring(number) .. "/comments?per_page=100'"
end

return {
  test_issue_state_projection_uses_a_distinct_full_entity_cache_slot = function()
    mock_author_policy()
    local repo = "owner/state-cache"
    local number = 41
    seam.mock_issue_view_selector(t, {
      repo = repo,
      number = number,
      title = "State cache",
      updated_at = "2026-06-03T01:02:02Z",
    }, state_selector, 1)

    local result = require("devloop.github_proxy_entity_view").fetch_issue_view_state(
      repo,
      number,
      "2026-06-03T01:02:02Z",
      { force_fresh = true }
    )
    local entity_view = require("devloop.github_proxy_entity_view")

    t.eq(result.exit_code, 0)
    t.is_true(tostring(cache_get(entity_view.entity_view_cache_key(repo, "issue-state", number)) or "") ~= "")
    t.eq(cache_get(entity_view.entity_view_cache_key(repo, "issue", number)), nil)
  end,

  test_issue_state_view_prefers_graphql_and_preserves_projection_cardinality = function()
    mock_author_policy()
    local repo = "owner/graphql-state"
    local number = 42
    local comments = {}
    for index = 1, 101 do
      table.insert(comments, {
        id = "IC_" .. tostring(index),
        body = "comment " .. tostring(index),
        author_login = "fkst-test-bot",
        created_at = "2026-06-03T01:00:00Z",
      })
    end
    seam.mock_issue_view_selector(t, {
      repo = repo,
      number = number,
      title = "GraphQL state",
      created_at = "2026-06-03T01:00:00Z",
      updated_at = "2026-06-03T01:02:03Z",
      labels = { "fkst-dev:enabled", "bug" },
      state = "OPEN",
      comments = comments,
      assignees = { "fkst-test-bot", "reviewer" },
      author_login = "fkst-test-bot",
    }, state_selector, 1)

    local result = require("devloop.github_proxy_entity_view").fetch_issue_view_state(
      repo,
      number,
      "2026-06-03T01:02:03Z",
      { force_fresh = true }
    )
    local state = parsers_issue.parse_issue_view_state(core, result.stdout)

    t.eq(result.exit_code, 0)
    t.eq(state.title, "GraphQL state")
    t.eq(state.created_at, "2026-06-03T01:00:00Z")
    t.eq(state.updated_at, "2026-06-03T01:02:03Z")
    t.eq(state.state, "OPEN")
    t.eq(#state.labels, 2)
    t.eq(#state.comments, 101)
    t.eq(state.comments[101].id, "IC_101")
    t.eq(#state.assignees, 2)
    t.eq(state.author_login, "fkst-test-bot")
  end,

  test_rate_limited_graphql_state_view_falls_back_to_paginated_rest = function()
    mock_author_policy()
    local repo = "owner/rest-fallback"
    local number = 43
    mock_graphql_failure(repo, number, "GraphQL: secondary rate limit (HTTP 403)")
    t.mock_command(issue_rest_command(repo, number), {
      stdout = '{"number":43,"title":"REST state","state":"open","created_at":"2026-06-03T01:00:00Z","updated_at":"2026-06-03T01:02:04Z","labels":[{"name":"fkst-dev:enabled"}],"assignees":[{"login":"reviewer"}],"user":{"login":"fkst-test-bot"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(comments_rest_command(repo, number), {
      stdout = '[[{"id":1,"body":"page one","user":{"login":"fkst-test-bot"},"created_at":"2026-06-03T01:00:01Z"}],[{"id":2,"body":"page two","user":{"login":"fkst-test-bot"},"created_at":"2026-06-03T01:00:02Z"}]]',
      stderr = "",
      exit_code = 0,
    })

    local result = require("devloop.github_proxy_entity_view").fetch_issue_view_state(
      repo,
      number,
      "2026-06-03T01:02:04Z",
      { force_fresh = true }
    )
    local state = parsers_issue.parse_issue_view_state(core, result.stdout)

    t.eq(result.exit_code, 0)
    t.eq(state.title, "REST state")
    t.eq(state.state, "OPEN")
    t.eq(#state.comments, 2)
    t.eq(state.comments[1].body, "page one")
    t.eq(state.comments[2].body, "page two")
  end,

  test_both_issue_state_surfaces_rate_limited_preserves_typed_failure = function()
    mock_author_policy()
    local repo = "owner/both-limited"
    local number = 44
    mock_graphql_failure(repo, number, "GraphQL: API rate limit already exceeded")
    t.mock_command(issue_rest_command(repo, number), {
      stdout = "",
      stderr = "gh: secondary rate limit (HTTP 403)",
      exit_code = 1,
    })

    local result = require("devloop.github_proxy_entity_view").fetch_issue_view_state(
      repo,
      number,
      "2026-06-03T01:02:05Z",
      { force_fresh = true }
    )

    t.eq(result.exit_code, 1)
    t.eq(result.error_class, "gh-rate-limited")
    t.eq(result.retryable, true)
  end,

  test_non_rate_graphql_state_failure_does_not_hide_adapter_error = function()
    mock_author_policy()
    local repo = "owner/graphql-invalid"
    local number = 45
    mock_graphql_failure(repo, number, "GraphQL: invalid field selection")

    local result = require("devloop.github_proxy_entity_view").fetch_issue_view_state(
      repo,
      number,
      "2026-06-03T01:02:06Z",
      { force_fresh = true }
    )

    t.eq(result.exit_code, 1)
    t.eq(result.error_class, "gh-command-failed")
    t.eq(result.retryable, false)
  end,
}
