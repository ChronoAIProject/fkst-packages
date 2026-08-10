local h = require("tests.proxy_integration_helpers")
local t = h.t
local opts = h.opts
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_comment_view = h.mock_comment_view
local count_calls = h.count_calls
local json_string = h.json_string

local issue_comment_create = "gh api --method POST repos/owner/x/issues/42/comments"
local origin = "github-devloop/issue/owner/x/42"

local function blueprint_marker(workflow, digest)
  return '<!-- fkst:github-devloop-workflow:blueprint:v1 origin="' .. origin
    .. '" workflow="' .. workflow .. '" digest="' .. digest .. '" -->'
end

local function event(workflow, digest)
  return {
    queue = "github_issue_comment_request",
    payload = {
      schema = "github-proxy.v1",
      repo = "owner/x",
      issue_number = 42,
      body = "Selected " .. workflow .. ".\n\n" .. blueprint_marker(workflow, digest),
      dedup_key = "workflow/blueprint-decision/" .. workflow .. "/" .. digest,
      exclusive_marker = {
        namespace = "github-devloop-workflow",
        marker = "blueprint",
        version = "v1",
        match = { origin = origin },
      },
    },
  }
end

local function mock_comment_write(body, dedup_key)
  local response_body = body .. "\n\n<!-- fkst:github-proxy:comment:" .. dedup_key .. " -->\n"
  t.mock_command("gh api --method POST repos/owner/x/issues/42/comments --field body=/tmp/fkst-github-proxy-comment-owner_x-issue-42.md", {
    stdout = '{"id":123456,"body":"' .. json_string(response_body) .. '","user":{"login":"fkst-test-bot"}}\n',
    exit_code = 0,
  })
end

local function run(request, name)
  mock_write_env("1")
  mock_bot_env()
  return t.run_department("departments/github_comment/main.lua", request, opts(name, {
    FKST_GITHUB_WRITE = "1",
  }))
end

return {
  test_first_trusted_marker_wins_and_conflicting_reliable_replay_is_rejected = function()
    local first = event("workflow-alpha", "digest-alpha")
    local conflicting = event("workflow-beta", "digest-beta")

    mock_comment_view({})
    mock_comment_write(first.payload.body, first.payload.dedup_key)
    local first_result = run(first, "exclusive-comment-first")
    t.eq(first_result.exit_code, 0)
    t.eq(count_calls(issue_comment_create), 1)

    mock_comment_view({
      { body = first.payload.body, author_login = "fkst-test-bot" },
    })
    local conflict_result = run(conflicting, "exclusive-comment-conflict-replay")
    t.eq(conflict_result.exit_code, 0)
    t.eq(count_calls(issue_comment_create), 1)
  end,

  test_identical_replay_remains_idempotent = function()
    local request = event("workflow-alpha", "digest-alpha")
    mock_comment_view({
      {
        body = request.payload.body .. "\n\n<!-- fkst:github-proxy:comment:" .. request.payload.dedup_key .. " -->",
        author_login = "fkst-test-bot",
      },
    })

    local result = run(request, "exclusive-comment-identical-replay")
    t.eq(result.exit_code, 0)
    t.eq(count_calls(issue_comment_create), 0)
  end,

  test_forged_marker_does_not_win_exclusion = function()
    local request = event("workflow-alpha", "digest-alpha")
    mock_comment_view({
      { body = blueprint_marker("forged-workflow", "forged-digest"), author_login = "ordinary-user" },
    })
    mock_comment_write(request.payload.body, request.payload.dedup_key)

    local result = run(request, "exclusive-comment-forged-marker")
    t.eq(result.exit_code, 0)
    t.eq(count_calls(issue_comment_create), 1)
  end,

  test_exclusive_request_fails_closed_when_body_does_not_establish_marker = function()
    local request = event("workflow-alpha", "digest-alpha")
    request.payload.body = "Missing the selected marker."
    mock_comment_view({})

    local result = run(request, "exclusive-comment-missing-marker")
    t.is_true(result.exit_code ~= 0)
    t.eq(count_calls(issue_comment_create), 0)
  end,

  test_claim_release_before_proxy_commit_suppresses_blueprint_write = function()
    local request = event("workflow-alpha", "digest-alpha")
    request.payload.claim = {
      owner = "fkst-test-bot",
      source_ref = {
        kind = "external",
        ref = "owner/x#issue/42",
      },
    }
    mock_comment_view({})
    t.mock_command("gh api repos/owner/x/issues/42", {
      stdout = '{"assignees":[],"labels":[]}\n',
      stderr = "",
      exit_code = 0,
    })

    local result = run(request, "exclusive-comment-claim-released")
    t.eq(result.exit_code, 0)
    t.eq(count_calls(issue_comment_create), 0)
  end,
}
