local graph = require("testkit.graph")
local gh_argv = require("testkit_internal.gh_argv_mock")
local author_policy = require("testkit_internal.github_author_policy")
local testing = require("testkit_internal.testing")
local t = fkst.test

local proposal_id = "github-devloop/issue/owner/repo/42"
local pr_proposal_id = "github-devloop/pr/owner/repo/7"
local review_proposal_id = "github-devloop/pr-review/owner/repo/7/review-v1/abcdef1"
local edge = "github-proxy.github_issue_comment_request -> github-proxy.github_comment"
local pr_edge = "github-proxy.github_pr_comment_request -> github-proxy.github_pr_comment"
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

local function append_file(path, body)
  local handle = assert(io.open(path, "a"))
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

local function comment_list(body)
  if body == nil then
    return "[[]]\n"
  end
  return '[[{"id":123456,"body":"'
    .. testing.escape_json_string(body, "\\u%04x")
    .. '","user":{"login":"fkst-test-bot"}}]]\n'
end

local function mock_real_comment_replace(existing_body)
  author_policy.mock_env(t, nil, { times = 2 })
  t.mock_command("gh api --paginate --slurp", {
    stdout = comment_list(existing_body),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(comment_edit, {
    stdout = '{"id":123456,"body":"edited","user":{"login":"fkst-test-bot"}}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function deliver_progress_request(payload, existing_body)
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
    stdout = "1",
    stderr = "",
    exit_code = 0,
  })
  if existing_body == nil then
    mock_real_comment_create()
  else
    mock_real_comment_replace(existing_body)
  end
  local trace = graph.require_quiescent(graph.run({
    queue = "github-proxy.github_issue_comment_request",
    payload = payload,
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
end

local function append_terminal_codex_status(log_root, run_id, tail_path, started_at_ms)
  local elapsed_ms = 125750
  local record = table.concat({
    '{"run_id":"', run_id,
    '","role":"implement","dept":"implement","proposal_id":"', proposal_id,
    '","dedup_key":"implementation-owner-repo-42-convergence"',
    ',"started_at":"2026-08-13T12:00:00Z","started_at_ms":', tostring(started_at_ms),
    ',"timeout_seconds":3600,"ended_at":"2026-08-13T12:02:05.750Z","ended_at_ms":',
    tostring(started_at_ms + elapsed_ms),
    ',"elapsed_ms":', tostring(elapsed_ms),
    ',"status":"completed","exit_code":0,"permit_slot":null,"output_tail_path":"',
    testing.escape_json_string(tail_path, "\\u%04x"),
    '"}',
  })
  append_file(
    log_root .. "/codex/fixture-" .. run_id .. ".log",
    "CODEX_OUTPUT_BEGIN:0\nCODEX_OUTPUT_END\nCODEX_STATUS:" .. record .. "\n"
  )
end

local function seed_abandoned_codex_status(log_root, tail_path, suffix, output_tail)
  local release = testing.seed_running_codex_status({
    env = { FKST_RUNTIME_LOG_DIR = log_root },
  }, {
    role = "implement",
    dept = "implement",
    proposal_id = proposal_id,
    dedup_key = "implementation-owner-repo-42-" .. suffix,
    status = "running",
    started_at = "2026-08-13T12:00:00Z",
    started_at_ms = now() * 1000 - 130000,
    timeout_seconds = 3600,
    output_tail_path = tail_path,
  })
  write_file(tail_path, output_tail)
  release()
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

local function pr_progress_raise(trace)
  local found = nil
  local count = 0
  for _, raised in ipairs(trace.raised or {}) do
    if raised.queue == "github-proxy.github_pr_comment_request" then
      count = count + 1
      found = raised
    end
  end
  t.eq(count, 1)
  return found
end

return {
  test_concurrent_review_progress_reaches_real_pr_comment_consumer = function()
    local log_root = top_level_log_root()
    local releases = {}
    for index, lane in ipairs({ "teleology", "fidelity" }) do
      local tail_path = log_root .. "/codex/pr-progress-" .. lane .. ".tail"
      releases[index] = testing.seed_running_codex_status({
        env = { FKST_RUNTIME_LOG_DIR = log_root },
      }, {
        role = "consensus",
        dept = "review_result",
        proposal_id = review_proposal_id,
        label = pr_proposal_id,
        dedup_key = "convergence:consensus:review-v1:" .. lane,
        status = "running",
        started_at = "2026-08-13T12:00:00Z",
        started_at_ms = now() * 1000 - 90000 + index,
        timeout_seconds = 3600,
        output_tail_path = tail_path,
      })
      write_file(tail_path, lane .. " reviewing\n")
    end

    local producer_trace = t.fire_raiser("codex_progress_poll")
    for _, release in ipairs(releases) do
      release()
    end

    local raised = pr_progress_raise(producer_trace)
    t.eq(raised.payload.repo, "owner/repo")
    t.eq(raised.payload.pr_number, 7)
    t.eq(raised.payload.replace_marker,
      '<!-- fkst:github-devloop-ops:codex-progress:v1 proposal="' .. pr_proposal_id .. '"')
    t.is_true(raised.payload.body:find("- Runs: `2`", 1, true) ~= nil)

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
        reference = "owner/repo#pr/7",
      },
    }, { max_steps = 2 }))
    graph.assert_covers(trace, { pr_edge })
    local proxy_step = graph.require_delivery(trace, {
      queue = "github-proxy.github_pr_comment_request",
      consumer = "github-proxy.github_pr_comment",
    })
    t.eq(proxy_step.exit_code, 0)
    t.eq(#proxy_step.raises, 0)
  end,

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

  test_running_progress_converges_to_one_distinct_terminal_render = function()
    local log_root = top_level_log_root()
    local tail_path = log_root .. "/codex/progress-card-convergence.tail"
    local started_at_ms = now() * 1000 - 130000
    local release = testing.seed_running_codex_status({
      env = { FKST_RUNTIME_LOG_DIR = log_root },
    }, {
      role = "implement",
      dept = "implement",
      proposal_id = proposal_id,
      dedup_key = "implementation-owner-repo-42-convergence",
      status = "running",
      started_at = "2026-08-13T12:00:00Z",
      started_at_ms = started_at_ms,
      timeout_seconds = 3600,
      output_tail_path = tail_path,
    })
    write_file(tail_path, "Implementing convergence card\nTests running\n")

    local running_trace = t.fire_raiser("codex_progress_poll")
    local running = progress_raise(running_trace)
    deliver_progress_request(running.payload, nil)
    local visible_running = read_file(comment_path)
    t.eq(running.payload.replace_snapshot.status, "running")
    t.is_true(visible_running:find('status="running"', 1, true) ~= nil)

    release()
    write_file(tail_path, "Implementation stopped\nFinal diagnostics preserved\n")
    append_terminal_codex_status(
      log_root,
      running.payload.replace_snapshot.run_id,
      tail_path,
      started_at_ms
    )

    local observed_terminal = fkst.codex_runs()
    t.eq(#observed_terminal.running, 0)
    t.eq(#observed_terminal.recent, 1)
    t.eq(observed_terminal.recent[1].run_id, running.payload.replace_snapshot.run_id)
    t.eq(observed_terminal.recent[1].status, "done")

    local terminal_trace = t.fire_raiser("codex_progress_poll")
    local terminal = progress_raise(terminal_trace)
    t.eq(terminal.payload.replace_snapshot.run_id, running.payload.replace_snapshot.run_id)
    t.eq(terminal.payload.replace_snapshot.status, "done")
    t.eq(terminal.payload.repo, running.payload.repo)
    t.eq(terminal.payload.issue_number, running.payload.issue_number)
    t.eq(terminal.payload.replace_marker, running.payload.replace_marker)
    t.is_true(terminal.payload.body:find("Outcome: `done`", 1, true) ~= nil)
    t.eq(terminal.payload.body:find("Elapsed:", 1, true), nil)

    deliver_progress_request(terminal.payload, visible_running)
    local visible_terminal = read_file(comment_path)
    t.is_true(visible_terminal:find("Outcome: `done`", 1, true) ~= nil)
    t.is_true(visible_terminal:find('status="done"', 1, true) ~= nil)
    t.eq(visible_terminal:find('status="running"', 1, true), nil)

    local repeated_trace = t.fire_raiser("codex_progress_poll")
    local repeated = progress_raise(repeated_trace)
    t.eq(repeated.payload.dedup_key, terminal.payload.dedup_key)
    t.eq(repeated.payload.body, terminal.payload.body)
    deliver_progress_request(repeated.payload, visible_terminal)
    t.eq(read_file(comment_path), visible_terminal)

    local edit_count = gh_argv.count_calls(t, comment_edit)
    deliver_progress_request(running.payload, visible_terminal)
    t.eq(gh_argv.count_calls(t, comment_edit), edit_count)
    t.eq(read_file(comment_path), visible_terminal)
  end,

  test_abandoned_terminal_progress_is_stable_across_observation_ticks = function()
    local log_root = top_level_log_root()
    local tail_path = log_root .. "/codex/progress-card-abandoned.tail"
    seed_abandoned_codex_status(
      log_root,
      tail_path,
      "abandoned-stable",
      "Implementation process disappeared\nLast recorded output\n"
    )

    local first_observation = fkst.codex_runs()
    t.eq(#first_observation.running, 0)
    t.eq(#first_observation.recent, 1)
    t.eq(first_observation.recent[1].status, "failed")
    t.eq(first_observation.recent[1].exit_code, -1)
    t.is_nil(first_observation.recent[1].ended_at_ms)

    local first = progress_raise(t.fire_raiser("codex_progress_poll"))
    t.eq(first.payload.body:find("Duration:", 1, true), nil)

    os.execute("sleep 0.02")
    local second_observation = fkst.codex_runs()
    t.is_nil(second_observation.recent[1].ended_at_ms)
    t.is_true(second_observation.recent[1].elapsed_ms > first_observation.recent[1].elapsed_ms)

    local second = progress_raise(t.fire_raiser("codex_progress_poll"))
    t.eq(second.payload.body, first.payload.body)
    t.eq(second.payload.dedup_key, first.payload.dedup_key)
  end,

  test_terminal_tail_mutation_intentionally_changes_body_and_dedup_key = function()
    local log_root = top_level_log_root()
    local tail_path = log_root .. "/codex/progress-card-tail-mutation.tail"
    seed_abandoned_codex_status(
      log_root,
      tail_path,
      "abandoned-tail-mutation",
      "First recorded terminal tail\n"
    )

    local first = progress_raise(t.fire_raiser("codex_progress_poll"))
    write_file(tail_path, "Later recorded terminal tail\n")
    local second = progress_raise(t.fire_raiser("codex_progress_poll"))

    t.is_true(first.payload.body:find("First recorded terminal tail", 1, true) ~= nil)
    t.is_true(second.payload.body:find("Later recorded terminal tail", 1, true) ~= nil)
    t.eq(second.payload.body == first.payload.body, false)
    t.eq(second.payload.dedup_key == first.payload.dedup_key, false)
  end,
}
