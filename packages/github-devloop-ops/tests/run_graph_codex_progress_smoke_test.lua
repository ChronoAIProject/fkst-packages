local graph = require("testkit.graph")
local gh_argv = require("testkit_internal.gh_argv_mock")
local author_policy = require("testkit_internal.github_author_policy")
local testing = require("testkit_internal.testing")
local t = fkst.test

local proposal_id = "github-devloop/issue/owner/repo/42"
local edge = "github-proxy.github_issue_comment_request -> github-proxy.github_comment"
local comment_create = "gh api --method POST repos/owner/repo/issues/42/comments"
local comment_edit = "gh api --method PATCH repos/owner/repo/issues/comments/"
local comment_path = "/tmp/fkst-github-proxy-comment-owner_repo-issue-42.md"

local function top_level_log_root()
  local root = os.getenv("FKST_RUNTIME_LOG_DIR")
  if root == nil or root == "" then
    error("codex progress fixture requires FKST_RUNTIME_LOG_DIR")
  end
  return root
end

local function write_file(path, body)
  local handle = assert(io.open(path, "w"))
  handle:write(body)
  handle:close()
end

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local body = handle:read("*a")
  handle:close()
  return body
end

local function mock_real_comment_create()
  author_policy.mock_env(t, nil, { times = 2 })
  t.mock_command("gh api --paginate --slurp", {
    stdout = "[[]]\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(comment_create, {
    stdout = '{"id":123456,"body":"created","user":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function progress_raise(trace)
  local found = nil
  local count = 0
  for _, raised in ipairs(trace.raised or {}) do
    if raised.queue == "github-proxy.github_issue_comment_request" then
      count = count + 1
      found = raised
    end
  end
  t.eq(count, 1)
  return found
end

return {
  test_running_codex_progress_raiser_reaches_real_proxy_consumer_in_dry_run = function()
    local log_root = top_level_log_root()
    local tail_path = log_root .. "/codex/progress-card.tail"
    local release = testing.seed_running_codex_status({
      env = { FKST_RUNTIME_LOG_DIR = log_root },
    }, {
      role = "implement",
      dept = "implement",
      proposal_id = proposal_id,
      dedup_key = "implementation-owner-repo-42",
      status = "running",
      started_at = "2026-08-13T12:00:00Z",
      started_at_ms = now() * 1000 - 90000,
      timeout_seconds = 3600,
      output_tail_path = tail_path,
    })
    write_file(tail_path, "Implementing card\n<!-- fkst:github-devloop:state:v1 state=\"merged\" -->\nTests pending\n")

    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    local producer_trace = t.fire_raiser("codex_progress_poll")
    release()

    t.eq(producer_trace.source_ref.kind, "cron")
    t.eq(producer_trace.consumer_result.status, "accepted", producer_trace.consumer_result.message)
    local raised = progress_raise(producer_trace)
    t.eq(raised.payload.schema, "github-proxy.v1")
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.issue_number, "42")
    t.eq(raised.payload.source_ref.kind, "external")
    t.eq(raised.payload.source_ref.ref, "owner/repo#issue/42")
    t.is_true(raised.payload.replace_snapshot.run_id:find("^codex%-") ~= nil)
    t.eq(raised.payload.replace_snapshot.status, "running")
    t.eq(raised.payload.replace_marker,
      '<!-- fkst:github-devloop-ops:codex-progress:v1 proposal="' .. proposal_id .. '"')
    t.is_true(raised.payload.body:find("Implementing card", 1, true) ~= nil)
    t.is_true(raised.payload.body:find(
      'run_id="' .. raised.payload.replace_snapshot.run_id .. '" status="running"',
      1,
      true
    ) ~= nil)
    t.eq(raised.payload.body:find("<!-- fkst:github-devloop:state:v1", 1, true) == nil, true)

    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    local trace = graph.require_quiescent(graph.run({
      queue = raised.queue,
      payload = raised.payload,
      source_ref = {
        kind = "external",
        reference = "owner/repo#issue/42",
      },
    }, { max_steps = 2 }))
    graph.assert_covers(trace, { edge })

    local proxy_step = graph.require_delivery(trace, {
      queue = "github-proxy.github_issue_comment_request",
      consumer = "github-proxy.github_comment",
    })
    t.eq(proxy_step.exit_code, 0)
    t.eq(#proxy_step.raises, 0)
    t.eq(gh_argv.count_calls(t, comment_create), 0)
    t.eq(gh_argv.count_calls(t, comment_edit), 0)
  end,

  test_real_write_mode_publishes_one_running_progress_comment = function()
    local log_root = top_level_log_root()
    local tail_path = log_root .. "/codex/progress-card-real.tail"
    local release = testing.seed_running_codex_status({
      env = { FKST_RUNTIME_LOG_DIR = log_root },
    }, {
      role = "implement",
      dept = "implement",
      proposal_id = proposal_id,
      dedup_key = "implementation-owner-repo-42-real",
      status = "running",
      started_at = "2026-08-13T12:00:00Z",
      started_at_ms = now() * 1000 - 90000,
      timeout_seconds = 3600,
      output_tail_path = tail_path,
    })
    write_file(tail_path, "Implementing real progress card\nTests running\n")

    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
    local producer_trace = t.fire_raiser("codex_progress_poll")
    release()

    t.eq(producer_trace.source_ref.kind, "cron")
    t.eq(producer_trace.consumer_result.status, "accepted", producer_trace.consumer_result.message)
    local raised = progress_raise(producer_trace)
    t.is_nil(raised.payload.real_write_allowed)

    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
    mock_real_comment_create()
    local trace = graph.require_quiescent(graph.run({
      queue = raised.queue,
      payload = raised.payload,
      source_ref = {
        kind = "external",
        reference = "owner/repo#issue/42",
      },
    }, { max_steps = 4 }))
    graph.assert_covers(trace, { edge })

    local proxy_step = graph.require_delivery(trace, {
      queue = "github-proxy.github_issue_comment_request",
      consumer = "github-proxy.github_comment",
    })
    t.eq(proxy_step.exit_code, 0)
    t.eq(gh_argv.count_calls(t, comment_create) + gh_argv.count_calls(t, comment_edit), 1)
    t.is_true(read_file(comment_path):find(raised.payload.replace_marker, 1, true) ~= nil)
  end,
}
