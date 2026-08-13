local graph = require("testkit.graph")
local testing = require("testkit_internal.testing")
local t = fkst.test

local proposal_id = "github-devloop/issue/owner/repo/42"
local edge = "github-proxy.github_issue_comment_request -> github-proxy.github_comment"

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
    t.eq(raised.payload.replace_marker,
      '<!-- fkst:github-devloop-ops:codex-progress:v1 proposal="' .. proposal_id .. '" -->')
    t.is_true(raised.payload.body:find("Implementing card", 1, true) ~= nil)
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
  end,

  test_real_write_mode_cannot_publish_running_only_progress = function()
    local log_root = top_level_log_root()
    local release = testing.seed_running_codex_status({
      env = { FKST_RUNTIME_LOG_DIR = log_root },
    }, {
      role = "implement",
      dept = "implement",
      proposal_id = proposal_id,
      status = "running",
      started_at = "2026-08-13T12:00:00Z",
      started_at_ms = now() * 1000 - 90000,
      timeout_seconds = 3600,
    })

    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
    local result = t.run_department("departments/codex_progress/main.lua", {
      queue = "devloop_codex_progress_tick",
      payload = { schema = "github-devloop-ops.codex-progress-tick.v1" },
    }, {
      env = { FKST_RUNTIME_LOG_DIR = log_root },
    })
    release()

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
