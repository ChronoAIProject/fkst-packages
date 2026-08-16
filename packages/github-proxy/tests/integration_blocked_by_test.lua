local h = require("tests.proxy_integration_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local calls_matching = h.calls_matching
local count_calls = h.count_calls

local function event(extra)
  local payload = {
    schema = "github-proxy.issue-blocked-by.v1",
    repo = "owner/x",
    blocked_issue_number = 42,
    blocking_issue_number = 99,
    dedup_key = "generic-workflow/fork/owner/x/issue/42/v1/blocked-by",
    source_ref = {
      kind = "external",
      ref = "owner/x#issue/42",
    },
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return {
    queue = "github_issue_blocked_by_request",
    payload = payload,
  }
end

local function blocked_by_json(nodes)
  local rendered = {}
  for _, node in ipairs(nodes or {}) do
    table.insert(rendered, string.format(
      '{"number":%d,"repository":{"nameWithOwner":"%s"}}',
      node.number,
      h.json_string(node.repo or "owner/x")
    ))
  end
  return '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":'
    .. tostring(#rendered)
    .. ',"pageInfo":{"hasNextPage":false},"nodes":['
    .. table.concat(rendered, ",")
    .. "]}}}}}\n"
end

local function mock_blocked_comments(comments)
  h.mock_comment_view(comments or {})
end

local function mock_blocked_by(nodes)
  t.mock_command("gh api graphql -f query=", {
    stdout = blocked_by_json(nodes or {}),
    stderr = "",
    exit_code = 0,
  })
end

local function mock_node_ids(blocking_id)
  t.mock_command("gh api repos/owner/x/issues/42", {
    stdout = '{"node_id":"I_blocked"}\n',
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api repos/owner/x/issues/99", {
    stdout = '{"node_id":"' .. h.json_string(blocking_id or "I_blocking") .. '"}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocking_entity_kind_response(stdout)
  t.mock_command("gh api graphql -f query=", {
    stdout = stdout,
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocking_entity_kind(kind)
  mock_blocking_entity_kind_response(
    '{"data":{"node":{"__typename":"' .. h.json_string(kind) .. '"}}}\n')
end

local function mock_add_blocked_by()
  t.mock_command("gh api graphql -f query=", {
    stdout = '{"data":{"addBlockedBy":{"clientMutationId":null}}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_blocked_by_marker_comment()
  t.mock_command("gh issue comment 42 --repo owner/x --body-file /tmp/fkst-github-proxy-blocked-by-", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_blocked_by_dry_run_logs_without_mutation = function()
    mock_write_env("")

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event(), opts("blocked-by-dry-run"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("addBlockedBy"), 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/42/comments?per_page=100"), 0)
  end,

  test_blocked_by_real_write_adds_graphql_edge_and_marker = function()
    mock_write_env("1")
    mock_bot_env()
    mock_blocked_comments({})
    mock_blocked_by({})
    mock_node_ids()
    mock_blocking_entity_kind("Issue")
    mock_add_blocked_by()
    mock_blocked_by_marker_comment()

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event(), opts("blocked-by-real", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("addBlockedBy"), 1)
    t.eq(count_calls("fkst-github-proxy-blocked-by-"), 1)
  end,

  test_blocked_by_existing_edge_skips_mutation_but_writes_marker = function()
    mock_write_env("1")
    mock_bot_env()
    mock_blocked_comments({})
    mock_blocked_by({ { repo = "owner/x", number = 99 } })
    mock_blocked_by_marker_comment()

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event(), opts("blocked-by-existing-edge", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("addBlockedBy"), 0)
    t.eq(count_calls("gh issue comment 42"), 1)
  end,

  test_blocked_by_existing_edge_and_trusted_marker_is_idempotent_noop = function()
    mock_write_env("1")
    mock_bot_env()
    local payload = event().payload
    mock_blocked_comments({
      {
        body = core.blocked_by_marker(payload.dedup_key, payload.blocked_issue_number, payload.blocking_issue_number),
        author_login = "fkst-test-bot",
      },
    })
    mock_blocked_by({ { repo = "owner/x", number = 99 } })

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event(), opts("blocked-by-existing-edge-marker", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("addBlockedBy"), 0)
    t.eq(count_calls("gh issue comment 42"), 0)
  end,

  test_blocked_by_missing_edge_with_trusted_marker_restores_edge_without_duplicate_marker = function()
    mock_write_env("1")
    mock_bot_env()
    local payload = event().payload
    mock_blocked_comments({
      {
        body = core.blocked_by_marker(payload.dedup_key, payload.blocked_issue_number, payload.blocking_issue_number),
        author_login = "fkst-test-bot",
      },
    })
    mock_blocked_by({})
    mock_node_ids()
    mock_blocking_entity_kind("Issue")
    mock_add_blocked_by()

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event(), opts("blocked-by-missing-edge-marker", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("addBlockedBy"), 1)
    t.eq(count_calls("gh issue comment 42"), 0)
  end,

  test_blocked_by_pull_request_blocker_fails_typed_without_mutation_or_marker = function()
    mock_write_env("1")
    mock_bot_env()
    mock_blocked_comments({})
    mock_blocked_by({})
    mock_node_ids("PR_opaque_blocking_id")
    mock_blocking_entity_kind("PullRequest")
    mock_blocked_by_marker_comment()

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event(), opts("blocked-by-pull-request-blocker", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 1)
    t.eq(core.error_class_from_message(result.error), "blocking-entity-not-issue")
    local kind_calls = calls_matching("__typename")
    t.eq(#kind_calls, 1)
    t.is_true(kind_calls[1].rendered:find("id=PR_opaque_blocking_id", 1, true) ~= nil)
    t.eq(count_calls("addBlockedBy"), 0)
    t.eq(count_calls("gh issue comment 42"), 0)
  end,

  test_blocked_by_missing_blocking_entity_kind_fails_closed_without_effects = function()
    mock_write_env("1")
    mock_bot_env()
    mock_blocked_comments({})
    mock_blocked_by({})
    mock_node_ids()
    mock_blocking_entity_kind_response('{"data":{"node":null}}\n')
    mock_blocked_by_marker_comment()

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event(), opts("blocked-by-missing-blocker-kind", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 1)
    t.eq(core.error_class_from_message(result.error), "blocking-entity-kind-response-malformed")
    t.eq(count_calls("addBlockedBy"), 0)
    t.eq(count_calls("gh issue comment 42"), 0)
  end,

  test_blocking_entity_kind_parser_requires_graphql_typename = function()
    t.eq(core.parse_blocking_entity_kind('{"data":{"node":{"__typename":"Issue"}}}'), "Issue")

    local ok, err = pcall(core.parse_blocking_entity_kind, '{"data":{"node":null}}')
    t.eq(ok, false)
    t.eq(core.error_class_from_message(err), "blocking-entity-kind-response-malformed")

    local is_issue, kind_err = pcall(core.assert_blocking_entity_is_issue, "PullRequest")
    t.eq(is_issue, false)
    t.eq(core.error_class_from_message(kind_err), "blocking-entity-not-issue")
  end,

  test_blocked_by_malformed_graphql_read_fails_closed_without_effects = function()
    mock_write_env("1")
    mock_bot_env()
    mock_blocked_comments({})
    t.mock_command("gh api graphql -f query=", {
      stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[',
      stderr = "",
      exit_code = 0,
    })

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event(), opts("blocked-by-malformed-graphql", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 1)
    t.eq(count_calls("addBlockedBy"), 0)
    t.eq(count_calls("gh issue comment 42"), 0)
  end,

  test_blocked_by_malformed_payload_fails_closed = function()
    mock_write_env("1")

    local result = t.run_department("departments/github_issue_blocked_by/main.lua", event({
      blocked_issue_number = nil,
    }), opts("blocked-by-malformed", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 1)
    t.eq(count_calls("addBlockedBy"), 0)
  end,

  test_blocked_by_graphql_contracts_are_named = function()
    local operations = core.github_graphql_queries

    t.eq(type(operations), "table")
    t.eq(core.github_graphql_command_templates.graphql_query, "GitHub GraphQL query")
    t.eq(type(operations.blocked_by), "string")
    t.eq(operations.blocking_entity_kind, "query($id:ID!){node(id:$id){__typename}}")
    t.eq(type(operations.add_blocked_by), "string")
    t.eq(operations.blocked_by:find("blockedBy(first:50)", 1, true) ~= nil, true)
    t.eq(operations.blocked_by:find("nodes{number repository{nameWithOwner}}", 1, true) ~= nil, true)
    t.eq(
      core.render_github_graphql_query("blocked_by", {
        owner = "owner",
        name = "x",
        issue_number = 42,
      }),
      '{repository(owner:"owner",name:"x"){issue(number:42){blockedBy(first:50){totalCount pageInfo{hasNextPage} nodes{number repository{nameWithOwner}}}}}}'
    )
  end,

  -- Contract test pinned to GitHub's real AddBlockedByInput schema (issueId +
  -- blockingIssueId). This asserts the named mutation contract, which is what
  -- actually failed in production: the input used 'blockedIssueId' (rejected by
  -- GitHub), so every block silently failed.
  test_add_blocked_by_mutation_uses_valid_schema_fields = function()
    local query = core.github_graphql_queries.add_blocked_by

    t.eq(query:find("addBlockedBy(input:{issueId:$b,blockingIssueId:$g})", 1, true) ~= nil, true)
    t.eq(query:find("blockedIssueId", 1, true), nil)
  end,
}
