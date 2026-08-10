local h = require("tests.proxy_integration_helpers")
local t = h.t
local core = h.core
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

local function resume_thread(thread)
  local ok, value = coroutine.resume(thread)
  if not ok then
    error(value, 0)
  end
  return value
end

return {
  test_overlapping_conflicting_requests_serialize_before_exclusion_read = function()
    local first = event("workflow-alpha", "digest-alpha")
    local conflicting = event("workflow-beta", "digest-beta")
    local comments = {}
    local reads, creates = 0, 0
    local held_locks = {}
    local contender_waited = false
    local first_written, conflicting_written = nil, nil
    local old_with_lock = with_lock
    local old_read_env = core.read_env
    local old_github = core.github

    with_lock = function(key, fn)
      while held_locks[key] do
        contender_waited = true
        coroutine.yield("waiting-for-lock")
      end
      held_locks[key] = true
      local result = fn()
      held_locks[key] = nil
      return result
    end
    core.read_env = function(name)
      if name == "FKST_GITHUB_WRITE" then return "1" end
      if name == "FKST_GITHUB_BOT_LOGIN" then return "fkst-test-bot" end
      return ""
    end
    core.github = function()
      return {}
    end

    local target = {
      kind = "issue",
      number = 42,
      number_field = "issue_number",
      view_label = "GitHub issue REST comments",
      comment_label = "GitHub issue comment",
      view_comments = function()
        reads = reads + 1
        local rendered = {}
        for index, comment in ipairs(comments) do
          rendered[#rendered + 1] = '{"id":' .. tostring(index)
            .. ',"body":"' .. json_string(comment.body)
            .. '","user":{"login":"' .. comment.author_login .. '"}}'
        end
        local snapshot = "[[" .. table.concat(rendered, ",") .. "]]\n"
        if reads == 1 then
          coroutine.yield("after-comment-read")
        end
        return { exit_code = 0, stdout = snapshot, stderr = "" }
      end,
      comment_create = function(_github, _repo, _number, path)
        creates = creates + 1
        local body = file.read(path)
        comments[#comments + 1] = { body = body, author_login = "fkst-test-bot" }
        return {
          exit_code = 0,
          stdout = '{"id":' .. tostring(creates) .. ',"body":"' .. json_string(body)
            .. '","user":{"login":"fkst-test-bot"}}\n',
          stderr = "",
        }
      end,
    }

    local ok, err = pcall(function()
      local first_thread = coroutine.create(function()
        first_written = core.write_comment_request(first.payload, target)
      end)
      local conflicting_thread = coroutine.create(function()
        conflicting_written = core.write_comment_request(conflicting.payload, target)
      end)

      t.eq(resume_thread(first_thread), "after-comment-read")
      t.eq(resume_thread(conflicting_thread), "waiting-for-lock")
      resume_thread(first_thread)
      t.eq(coroutine.status(first_thread), "dead")
      resume_thread(conflicting_thread)
      t.eq(coroutine.status(conflicting_thread), "dead")
    end)
    core.github = old_github
    core.read_env = old_read_env
    with_lock = old_with_lock
    if not ok then
      error(err, 0)
    end

    t.is_true(contender_waited)
    t.eq(reads, 2)
    t.eq(creates, 1)
    t.eq(#comments, 1)
    t.is_true(first_written ~= nil)
    t.is_nil(conflicting_written)
    t.is_true(comments[1].body:find(blueprint_marker("workflow-alpha", "digest-alpha"), 1, true) ~= nil)
    t.is_nil(comments[1].body:find(blueprint_marker("workflow-beta", "digest-beta"), 1, true))
  end,

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
