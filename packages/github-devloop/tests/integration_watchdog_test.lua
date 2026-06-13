local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

local function opts(name)
  local runtime = "/tmp/fkst-packages-test/github-devloop/" .. tostring(now()) .. "/" .. tostring(name)
  return {
    env = {
      FKST_RUNTIME_ROOT = runtime,
      FKST_GITHUB_REPO = "owner/repo",
      FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
      FKST_GITHUB_WRITE = "",
      FKST_DEVLOOP_UPSTREAM_BRANCH = "dev",
      FKST_DEVLOOP_INTEGRATION_BRANCH = "integration/dev",
    },
    runtime = runtime,
  }
end

local function run_observability(name)
  local run_opts = opts(name or "watchdog")
  return t.run_department("departments/observability/main.lua", {
    queue = "devloop_observe_tick",
    payload = { schema = "github-devloop.observe-tick.v1" },
  }, run_opts)
end

local function shell_single_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function current_window()
  return os.date("!%Y-%m-%dT%HZ", math.floor(now() / 3600) * 3600)
end

local function mock_env(extra)
  extra = extra or {}
  local snapshot_dir = "/tmp/fkst-packages-test/github-devloop/runtime/watchdog-incidents/" .. current_window()
  os.execute("mkdir -p " .. shell_single_quote(snapshot_dir))
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
  end
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _, name in ipairs({ "GH_TOKEN", "GITHUB_TOKEN" }) do
    t.mock_command('if [ -n "${' .. name .. ':-}" ]; then printf present; fi', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop/runtime",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_DEVLOOP_SUPERVISE_LOG"', {
      stdout = extra.supervise_log or "",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 8 do
    t.mock_command("install -d -m 0755", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function json_string(value)
  return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function render_comment(body, author, created_at)
  return string.format(
    '{"body":"%s","author":{"login":"%s"},"createdAt":"%s"}',
    json_string(body),
    json_string(author or "fkst-test-bot"),
    json_string(created_at or "2026-06-03T01:02:03Z")
  )
end

local function mock_all_issue_lists(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    local number = type(item) == "table" and item.number or item
    local state = type(item) == "table" and item.state or "open"
    table.insert(rendered, string.format('{"number":%d,"state":"%s"}', number, json_string(state)))
  end
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/issues?state=open&labels=fkst-dev%3Aenabled&per_page=100'", {
    stdout = "[[" .. table.concat(rendered, ",") .. "]]\n",
    stderr = "",
    exit_code = 0,
  })
  for _, state in ipairs(core._state_order) do
    t.mock_command("gh api --paginate --slurp 'repos/owner/repo/issues?state=open&labels=" .. core.state_label(state):gsub(":", "%%3A") .. "&per_page=100'", {
      stdout = "[[]]\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_pr_list(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    local number = type(item) == "table" and item.number or item
    local state = type(item) == "table" and item.state or "open"
    table.insert(rendered, string.format('{"number":%d,"state":"%s"}', number, json_string(state)))
  end
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&per_page=100'", {
    stdout = "[[" .. table.concat(rendered, ",") .. "]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_view(comments, updated_at)
  t.mock_command("--json title,updatedAt,comments,state", {
    stdout = '{"title":"Observed issue","updatedAt":"' .. json_string(updated_at or "2026-06-03T01:02:03Z")
      .. '","state":"OPEN","comments":[' .. table.concat(comments or {}, ",") .. "]}\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_recent_closed_issues(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    local labels = {}
    for _, label in ipairs(item.labels or {}) do
      table.insert(labels, '{"name":"' .. json_string(label):sub(2, -2) .. '"}')
    end
    table.insert(rendered, string.format(
      '{"number":%d,"title":"%s","closedAt":"%s","labels":[%s]}',
      tonumber(item.number),
      json_string(item.title or "Closed issue"):sub(2, -2),
      json_string(item.closed_at or "2026-06-03T01:02:03Z"):sub(2, -2),
      table.concat(labels, ",")
    ))
  end
  t.mock_command("--state closed --limit 30 --json number,title,closedAt,labels", {
    stdout = "[" .. table.concat(rendered, ",") .. "]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function find_raise(result, queue, predicate)
  for _, raised in ipairs(result.raises or {}) do
    if raised.queue == queue and (predicate == nil or predicate(raised.payload)) then
      return raised
    end
  end
  return nil
end

local function version_minutes_ago(minutes)
  return os.date("!%Y-%m-%dT%H-%M-%SZ", now() - (tonumber(minutes) or 0) * 60)
end

return {
  test_watchdog_files_merge_ready_queue_starvation_alert = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_recent_closed_issues({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "merge-ready", version_minutes_ago(11)), "fkst-test-bot"),
    })

    local result = run_observability("watchdog-queue-starvation")

    t.eq(result.exit_code, 0)
    local raised = find_raise(result, "github-proxy.github_issue_create_request", function(payload)
      return payload.dedup_key == "watchdog/queue-starvation/merge-ready/" .. current_window()
    end)
    t.is_true(raised ~= nil)
    local payload = raised.payload
    t.eq(payload.schema, "github-proxy.issue-create.v1")
    t.eq(payload.repo, "owner/repo")
    t.eq(payload.title, "Self-diagnosis watchdog: merge queue starvation")
    t.eq(payload.labels[1], "fkst-watchdog")
    t.eq(payload.source_ref.kind, "external")
    t.eq(payload.source_ref.ref, "owner/repo#watchdog/queue-starvation")
    t.eq(payload._watchdog_detector, nil)
    t.is_true(payload.body:find("Detector: queue-starvation", 1, true) ~= nil)
    t.is_true(payload.body:find("queue_head=#42", 1, true) ~= nil)
    t.is_true(payload.body:find("last_merge_age_minutes=unknown", 1, true) ~= nil)
    t.is_true(payload.body:find("Evidence snapshot: /tmp/fkst-packages-test/github-devloop/runtime/watchdog-incidents/", 1, true) ~= nil)
    t.is_true(payload.body:find("Do not repair runtime state in place", 1, true) ~= nil)
    local snapshot = payload.body:match("Evidence snapshot: ([^\n]+)")
    local snapshot_body = file.read(snapshot)
    t.is_true(snapshot_body:find("detector: queue-starvation", 1, true) ~= nil)
    t.is_true(snapshot_body:find("dedup_key: " .. payload.dedup_key, 1, true) ~= nil)
    t.is_true(snapshot_body:find("queue_head=#42", 1, true) ~= nil)
  end,

  test_watchdog_files_intake_silence_for_enabled_issue_without_decision = function()
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_recent_closed_issues({})
    mock_issue_view({}, os.date("!%Y-%m-%dT%H:%M:%SZ", now() - 11 * 60))

    local result = run_observability("watchdog-intake-silence")

    t.eq(result.exit_code, 0)
    local raised = find_raise(result, "github-proxy.github_issue_create_request", function(payload)
      return payload.title == "Self-diagnosis watchdog: intake silence"
    end)
    t.is_true(raised ~= nil)
    t.eq(raised.payload.source_ref.ref, "owner/repo#issue/42")
    t.is_true(raised.payload.dedup_key:find("watchdog/intake-silence/github-devloop/issue/owner/repo/42/", 1, true) == 1)
    t.is_true(raised.payload.body:find("Detector: intake-silence", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("issue=#42", 1, true) ~= nil)
  end,

  test_watchdog_skips_intake_silence_when_trusted_intake_decision_exists = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_recent_closed_issues({})
    mock_issue_view({
      render_comment('<!-- fkst:github-devloop:intake-decision:v1 proposal="' .. proposal_id .. '" decision="enable" class="standard" dedup="intake/42" -->', "fkst-test-bot"),
    }, os.date("!%Y-%m-%dT%H:%M:%SZ", now() - 11 * 60))

    local result = run_observability("watchdog-intake-decision")

    t.eq(result.exit_code, 0)
    t.eq(find_raise(result, "github-proxy.github_issue_create_request", function(payload)
      return payload.title == "Self-diagnosis watchdog: intake silence"
    end), nil)
  end,

  test_watchdog_files_budget_breach_when_escalation_attempts_exceeded = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = version_minutes_ago(130) .. "/timeout/reviewing/3"
    mock_env()
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_recent_closed_issues({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "reviewing", version), "fkst-test-bot"),
    })

    local result = run_observability("watchdog-budget-breach")

    t.eq(result.exit_code, 0)
    local raised = find_raise(result, "github-proxy.github_issue_create_request", function(payload)
      return payload.title == "Self-diagnosis watchdog: liveness budget breach"
    end)
    t.is_true(raised ~= nil)
    t.eq(raised.payload.source_ref.ref, "owner/repo#issue/42")
    t.is_true(raised.payload.body:find("Detector: budget-breach", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("state=reviewing", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("timeout_attempt=3", 1, true) ~= nil)
    t.is_true(raised.payload.body:find("escalate_after_attempts=3", 1, true) ~= nil)
  end,

  test_watchdog_snapshots_generation_log_before_filing_alert = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local supervise_log = "/tmp/fkst-packages-test/github-devloop/supervise-20260613T010203Z.log"
    mock_env({ supervise_log = supervise_log })
    t.mock_command("tail -c 12000", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    mock_all_issue_lists({ 42 })
    mock_pr_list({})
    mock_recent_closed_issues({})
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "merge-ready", version_minutes_ago(11)), "fkst-test-bot"),
    })

    local result = run_observability("watchdog-log-snapshot")

    t.eq(result.exit_code, 0)
    local raised = find_raise(result, "github-proxy.github_issue_create_request", function(payload)
      return payload.title == "Self-diagnosis watchdog: merge queue starvation"
    end)
    t.is_true(raised ~= nil)
    t.is_true(raised.payload.body:find("%.supervise%.log", 1, false) ~= nil)
    local has_tail = false
    for _, call in ipairs(t.command_calls()) do
      if call.rendered:find("tail -c 12000", 1, true) ~= nil
        and call.rendered:find(supervise_log, 1, true) ~= nil
        and call.rendered:find(".supervise.log", 1, true) ~= nil then
        has_tail = true
      end
    end
    t.is_true(has_tail)
  end,

  test_watchdog_skips_queue_starvation_when_recent_merge_event_exists = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local merged_proposal_id = "github-devloop/issue/owner/repo/41"
    mock_env()
    mock_all_issue_lists({ 41, 42 })
    mock_pr_list({})
    mock_recent_closed_issues({})
    mock_issue_view({
      render_comment(core.state_marker(merged_proposal_id, "merged", version_minutes_ago(2)), "fkst-test-bot", os.date("!%Y-%m-%dT%H:%M:%SZ", now() - 2 * 60)),
      render_comment(core.merged_marker(merged_proposal_id, 7, version_minutes_ago(2), "def456"), "fkst-test-bot", os.date("!%Y-%m-%dT%H:%M:%SZ", now() - 2 * 60)),
    })
    mock_issue_view({
      render_comment(core.state_marker(proposal_id, "merge-ready", version_minutes_ago(11)), "fkst-test-bot"),
    })

    local result = run_observability("watchdog-recent-merge")

    t.eq(result.exit_code, 0)
    t.eq(find_raise(result, "github-proxy.github_issue_create_request", function(payload)
      return payload.title == "Self-diagnosis watchdog: merge queue starvation"
    end), nil)
  end,
}
