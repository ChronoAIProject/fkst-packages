local h = require("tests.proxy_integration_helpers")
local t = h.t
local core = h.core
local opts = h.opts
local mock_write_env = h.mock_write_env
local mock_bot_env = h.mock_bot_env
local mock_pr_comment_view = h.mock_pr_comment_view
local mock_pr_comment_write = h.mock_pr_comment_write
local count_calls = h.count_calls

local function run_pr_comment_with_log_capture(input_event)
  local seen = {}
  local previous_info = log.info
  log.info = function(message)
    table.insert(seen, tostring(message))
    previous_info(message)
  end

  local loaded, result = pcall(function()
    require("departments.github_pr_comment.main")
    pipeline(input_event)
  end)

  log.info = previous_info
  if not loaded then
    error(result)
  end
  return seen
end

local function contains_all(line, expected)
  for _, part in ipairs(expected) do
    if line:find(part, 1, true) == nil then
      return false
    end
  end
  return true
end

local function has_log_line(lines, expected)
  for _, line in ipairs(lines) do
    if contains_all(line, expected) then
      return true
    end
  end
  return false
end

local function event(extra)
  local payload = {
    schema = "github-proxy.v1",
    repo = "owner/x",
    pr_number = 7,
    body = "PR-local review note",
    dedup_key = "review-result/comment/owner/x/7/v1",
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

return {
  test_pr_comment_request_dry_run_does_not_view_or_write = function()
    mock_write_env("")

    local result = t.run_department("departments/github_pr_comment/main.lua", event(), opts("pr-comment-dry-run"))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr view"), 0)
    t.eq(count_calls("gh pr comment"), 0)
  end,

  test_pr_comment_request_dry_run_logs_outbound = function()
    mock_write_env("")

    local lines = run_pr_comment_with_log_capture(event())

    t.is_true(has_log_line(lines, {
      "github-proxy",
      "tag=OUTBOUND",
      "mode=dry-run",
      "repo=owner/x",
      "pr=7",
      "dedup_key=review-result/comment/owner/x/7/v1",
      "reason=FKST_GITHUB_WRITE!=1",
    }))
    t.eq(count_calls("gh pr view"), 0)
    t.eq(count_calls("gh pr comment"), 0)
  end,

  test_pr_comment_request_missing_required_fields_fail_closed = function()
    mock_write_env("1")
    mock_bot_env()

    local result = t.run_department("departments/github_pr_comment/main.lua", {
      queue = "github_pr_comment_request",
      payload = {
        schema = "github-proxy.v1",
        repo = "owner/x",
        body = "missing pr number",
        dedup_key = "missing/pr-number",
        source_ref = {
          kind = "external",
          ref = "owner/x#pr/7",
        },
      },
    }, opts("pr-comment-missing-pr", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr view"), 0)
    t.eq(count_calls("gh pr comment"), 0)
  end,

  test_pr_comment_request_trusted_dedup_skips_write = function()
    mock_write_env("1")
    mock_bot_env()
    mock_pr_comment_view({
      {
        body = "already wrote\n" .. core.comment_marker("review-result/comment/owner/x/7/v1"),
        author = "fkst-test-bot",
      },
    })
    mock_pr_comment_write()

    local lines = run_pr_comment_with_log_capture(event())

    t.is_true(has_log_line(lines, {
      "github-proxy",
      "tag=OUTBOUND",
      "mode=real",
      "repo=owner/x",
      "pr=7",
      "dedup_key=review-result/comment/owner/x/7/v1",
      "result=deduped",
    }))
    t.eq(count_calls("gh pr view"), 1)
    t.eq(count_calls("gh pr comment"), 0)
  end,

  test_pr_comment_request_real_write_uses_gh_pr_comment = function()
    mock_write_env("1")
    mock_bot_env()
    mock_pr_comment_view("existing PR comment")
    mock_pr_comment_write()

    local result = t.run_department("departments/github_pr_comment/main.lua", event(), opts("pr-comment-write", {
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_calls("gh pr view"), 1)
    t.eq(count_calls("gh pr comment"), 1)
  end,

  test_pr_comment_request_real_write_logs_outbound = function()
    mock_write_env("1")
    mock_bot_env()
    mock_pr_comment_view("existing PR comment")
    mock_pr_comment_write()

    local lines = run_pr_comment_with_log_capture(event())

    t.is_true(has_log_line(lines, {
      "github-proxy",
      "tag=OUTBOUND",
      "mode=real",
      "repo=owner/x",
      "pr=7",
      "dedup_key=review-result/comment/owner/x/7/v1",
      "result=commented",
    }))
    t.eq(count_calls("gh pr view"), 1)
    t.eq(count_calls("gh pr comment"), 1)
  end,
}
