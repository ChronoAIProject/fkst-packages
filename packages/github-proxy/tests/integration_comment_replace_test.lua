local h = require("tests.proxy_integration_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_pr_comment_view = h.mock_pr_comment_view
local mock_pr_comment_write = h.mock_pr_comment_write
local count_calls = h.count_calls
local pr_comment_create = "gh api --method POST repos/owner/x/issues/7/comments"

local function event(extra)
  local payload = {
    schema = "github-proxy.v1",
    repo = "owner/x",
    pr_number = 7,
    body = "Working: fix\n\n<!-- fkst:generic-workflow:work-card:v1 proposal=\"generic-workflow/issue/owner/x/42\" -->",
    dedup_key = "work-card/generic-workflow/issue/owner/x/42/fix/v1/running",
    replace_marker = "<!-- fkst:generic-workflow:work-card:v1 proposal=\"generic-workflow/issue/owner/x/42\" -->",
    source_ref = {
      kind = "external",
      ref = "owner/x#pr/7",
    },
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return {
    queue = "github_pr_comment_request",
    payload = payload,
  }
end

local function mock_comment_edit()
  t.mock_command("gh api --method PATCH repos/owner/x/issues/comments/123456 --field body=/tmp/fkst-github-proxy-comment-owner_x-pr-7.md", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_comment_edit_result(comment_id, exit_code, stderr)
  t.mock_command("gh api --method PATCH repos/owner/x/issues/comments/" .. tostring(comment_id) .. " --field body=/tmp/fkst-github-proxy-comment-owner_x-pr-7.md", {
    stdout = "",
    stderr = stderr or "",
    exit_code = exit_code or 0,
  })
end

local function timeout_attempt_body(round)
  return "generic-workflow timeout redrive attempt: implementing " .. tostring(round)
    .. "\n\n"
    .. '<!-- fkst:generic-workflow:timeout-attempt:v2 proposal="generic-workflow/issue/owner/x/42" state="implementing" liveness_class_id="producing_revision" generation_key="gen-1" round="' .. tostring(round) .. '" dedup="timeout-attempt:v2:implementing/producing_revision/gen-1/' .. tostring(round) .. '" source_ref_kind="external" source_ref="owner/x#issue/42" -->'
    .. "\n"
    .. '<!-- fkst:generic-workflow:timeout-attempt:latest:v1 proposal="generic-workflow/issue/owner/x/42" state="implementing" liveness_class_id="producing_revision" generation_key="gen-1" -->'
    .. "\n⟦AI:FKST⟧"
end

local progress_proposal_id = "github-devloop/issue/owner/x/42"
local progress_replace_marker = '<!-- fkst:github-devloop-ops:codex-progress:v1 proposal="'
  .. progress_proposal_id .. '"'
local progress_comment_path = "/tmp/fkst-github-proxy-comment-owner_x-pr-7.md"

local function progress_body(run_id, status, output)
  return tostring(output)
    .. "\n\n"
    .. progress_replace_marker
    .. ' run_id="' .. tostring(run_id)
    .. '" status="' .. tostring(status)
    .. '" -->'
end

local function progress_event(run_id, status, output)
  return event({
    body = progress_body(run_id, status, output),
    dedup_key = table.concat({ "codex-progress", run_id, status, output }, "/"),
    replace_marker = progress_replace_marker,
    replace_snapshot = {
      run_id = run_id,
      status = status,
    },
  })
end

local function run_progress_replace(name, next_event, existing_body)
  mock_write_env("1")
  mock_bot_env()
  mock_pr_comment_view({
    {
      databaseId = 123456,
      body = existing_body,
      author_login = "fkst-test-bot",
    },
  })
  mock_comment_edit()
  mock_pr_comment_write()
  return t.run_department("departments/github_pr_comment/main.lua", next_event, opts(name, {
    FKST_GITHUB_WRITE = "1",
  }))
end

return {
  test_replace_marker_edits_existing_trusted_comment = function()
    mock_write_env("1")
    mock_bot_env()
    mock_pr_comment_view({
      {
        id = "IC_kwDOSwWu288AAAABF40Vmg",
        databaseId = 123456,
        body = "old card\n" .. event().payload.replace_marker,
        author_login = "fkst-test-bot",
      },
    })
    mock_comment_edit()
    mock_pr_comment_write()

    local result = t.run_department("departments/github_pr_comment/main.lua", event(), opts("comment-replace-edit", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/7/comments?per_page=100"), 1)
    t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/123456 --field body=@"), 1)
    t.eq(count_calls("issues/comments/IC_kwDOSwWu288AAAABF40Vmg"), 0)
    t.eq(count_calls(pr_comment_create), 0)
  end,

  test_replace_marker_creates_when_card_is_absent = function()
    mock_write_env("1")
    mock_bot_env()
    mock_pr_comment_view({})
    mock_comment_edit()
    mock_pr_comment_write()

    local result = t.run_department("departments/github_pr_comment/main.lua", event(), opts("comment-replace-create", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/7/comments?per_page=100"), 1)
    t.eq(count_calls("gh api --method PATCH"), 0)
    t.eq(count_calls(pr_comment_create), 1)
  end,

  test_replace_marker_falls_back_to_create_when_edit_target_is_stale = function()
    t.eq(core.stale_comment_target_error_class(), "stale-comment-target")
    mock_write_env("1")
    mock_bot_env()
    mock_pr_comment_view({
      {
        databaseId = 123456,
        body = "old card\n" .. event().payload.replace_marker,
        author_login = "fkst-test-bot",
      },
    })
    mock_comment_edit_result(123456, 1, "gh: Not Found")
    mock_pr_comment_view({})
    mock_pr_comment_write()

    local result = t.run_department("departments/github_pr_comment/main.lua", event(), opts("comment-replace-stale-edit-create", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/7/comments?per_page=100"), 2)
    t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/123456 --field body=@"), 1)
    t.eq(count_calls(pr_comment_create), 1)
  end,

  test_replace_marker_rereads_once_when_edit_404_then_edits_refreshed_comment = function()
    mock_write_env("1")
    mock_bot_env()
    mock_pr_comment_view({
      {
        databaseId = 123456,
        body = "old card\n" .. event().payload.replace_marker,
        author_login = "fkst-test-bot",
      },
    })
    mock_comment_edit_result(123456, 1, "HTTP 404: Not Found")
    mock_pr_comment_view({
      {
        databaseId = 654321,
        body = "new card\n" .. event().payload.replace_marker,
        author_login = "fkst-test-bot",
      },
    })
    mock_comment_edit_result(654321)
    mock_pr_comment_write()

    local result = t.run_department("departments/github_pr_comment/main.lua", event(), opts("comment-replace-404-reread-edit", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/7/comments?per_page=100"), 2)
    t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/123456 --field body=@"), 1)
    t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/654321 --field body=@"), 1)
    t.eq(count_calls(pr_comment_create), 0)
  end,

  test_same_run_terminal_progress_card_rejects_late_running_after_edit_404_refresh = function()
    local run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000000"
    mock_write_env("1")
    mock_bot_env()
    mock_pr_comment_view({
      {
        databaseId = 123456,
        body = progress_body(run_id, "running", "Working"),
        author_login = "fkst-test-bot",
      },
    })
    mock_comment_edit_result(123456, 1, "HTTP 404: Not Found")
    mock_pr_comment_view({
      {
        databaseId = 654321,
        body = progress_body(run_id, "done", "Completed"),
        author_login = "fkst-test-bot",
      },
    })
    mock_comment_edit_result(654321)
    mock_pr_comment_write()

    local result = t.run_department(
      "departments/github_pr_comment/main.lua",
      progress_event(run_id, "running", "Stale work"),
      opts("comment-progress-404-refresh-terminal", {
        FKST_GITHUB_WRITE = "1",
      })
    )

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/7/comments?per_page=100"), 2)
    t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/123456 --field body=@"), 1)
    t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/654321 --field body=@"), 0)
    t.eq(count_calls(pr_comment_create), 0)
  end,

  test_parse_issue_comments_preserves_comment_id = function()
    local comments = core.parse_issue_comments('{"comments":[{"id":"IC_kwabc","databaseId":999,"body":"hello","author":{"login":"fkst-test-bot"}}]}')
    t.eq(comments[1].id, "999")
    t.eq(core.trusted_comment_with_fragment(comments, "hello", "fkst-test-bot").id, "999")
  end,

  test_timeout_attempt_replace_skips_stale_lower_round = function()
    mock_write_env("1")
    mock_bot_env()
    local replace_marker = '<!-- fkst:generic-workflow:timeout-attempt:latest:v1 proposal="generic-workflow/issue/owner/x/42" state="implementing" liveness_class_id="producing_revision" generation_key="gen-1" -->'
    mock_pr_comment_view({
      {
        databaseId = 123456,
        body = timeout_attempt_body(3),
        author_login = "fkst-test-bot",
      },
    })
    mock_pr_comment_write()

    local result = t.run_department("departments/github_pr_comment/main.lua", event({
      body = timeout_attempt_body(2),
      dedup_key = "timeout-attempt:v2/generic-workflow/issue/owner/x/42/implementing/producing_revision/gen-1/2",
      replace_marker = replace_marker,
    }), opts("comment-replace-timeout-attempt-stale", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --paginate --slurp repos/owner/x/issues/7/comments?per_page=100"), 1)
    t.eq(count_calls("gh api --method PATCH"), 0)
    t.eq(count_calls(pr_comment_create), 0)
    t.eq(#result.raises, 0)
  end,

  test_same_run_terminal_progress_card_rejects_late_running_replay = function()
    for index, status in ipairs({ "done", "failed" }) do
      local run_id = "codex-01ARZ3NDEKTSV4RRFFQ600000" .. tostring(index)
      local terminal_output = "Terminal " .. status
      local initial_running = progress_event(run_id, "running", "Working")
      local terminal = progress_event(run_id, status, terminal_output)

      local terminal_result = run_progress_replace(
        "comment-progress-terminal-" .. status,
        terminal,
        initial_running.payload.body
      )
      t.eq(terminal_result.exit_code, 0)
      local terminal_card = file.read(progress_comment_path)
      t.is_true(terminal_card:find(terminal_output, 1, true) ~= nil)

      local replay_result = run_progress_replace(
        "comment-progress-late-running-" .. status,
        progress_event(run_id, "running", "Stale work"),
        terminal_card
      )
      t.eq(replay_result.exit_code, 0)
      t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/123456 --field body=@"), index)
      local visible_card = file.read(progress_comment_path)
      t.is_true(visible_card:find(terminal_output, 1, true) ~= nil)
      t.eq(visible_card:find("Stale work", 1, true), nil)
    end
  end,

  test_same_run_running_progress_refreshes_remain_replaceable = function()
    local run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000002"
    local first = progress_event(run_id, "running", "Phase one")
    local first_result = run_progress_replace(
      "comment-progress-running-first",
      first,
      progress_body(run_id, "running", "Starting")
    )
    t.eq(first_result.exit_code, 0)

    local first_card = file.read(progress_comment_path)
    local second_result = run_progress_replace(
      "comment-progress-running-second",
      progress_event(run_id, "running", "Phase two"),
      first_card
    )
    t.eq(second_result.exit_code, 0)
    t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/123456 --field body=@"), 2)
    local visible_card = file.read(progress_comment_path)
    t.is_true(visible_card:find("Phase two", 1, true) ~= nil)
    t.eq(visible_card:find("Phase one", 1, true), nil)
  end,

  test_terminal_progress_for_another_run_does_not_order_running_replace = function()
    local terminal_run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000003"
    local running_run_id = "codex-01ARZ3NDEKTSV4RRFFQ6000004"
    local result = run_progress_replace(
      "comment-progress-distinct-run",
      progress_event(running_run_id, "running", "New run"),
      progress_body(terminal_run_id, "failed", "Old run failed")
    )

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh api --method PATCH repos/owner/x/issues/comments/123456 --field body=@"), 1)
    local visible_card = file.read(progress_comment_path)
    t.is_true(visible_card:find("New run", 1, true) ~= nil)
  end,
}
