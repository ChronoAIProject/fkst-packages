local graph = require("testkit.graph")
local t = fkst.test

local repo = "owner/repo"

local function source_ref(issue_number)
  local reference = repo .. "#issue/" .. tostring(issue_number)
  return {
    kind = "external",
    ref = reference,
    reference = reference,
  }
end

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  return text
end

local function issue_rest_json(issue_number, body)
  return string.format(
    '{"number":%d,"title":"Marketing radar %d","body":"%s","html_url":"https://github.example/%s/issues/%d","updated_at":"2026-07-28T09:00:00Z","state":"open","labels":[{"name":"auto-twitter-marketing"}],"assignees":[],"user":{"login":"fkst-test-bot"}}\n',
    issue_number,
    issue_number,
    json_escape(body),
    repo,
    issue_number
  )
end

local function mock_common_env()
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_DEVLOOP_MANAGED_BOT_LOGINS"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_AUTHORIZED_LOGINS"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_issue_read(issue_number, body)
  t.mock_command("gh api repos/" .. repo .. "/issues/" .. tostring(issue_number), {
    stdout = issue_rest_json(issue_number, body),
    stderr = "",
    exit_code = 0,
  })
  t.mock_command("gh api --paginate --slurp 'repos/" .. repo .. "/issues/" .. tostring(issue_number) .. "/comments?per_page=100'", {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function issue_event(issue_number)
  return {
    queue = "github-proxy.github_issue_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = repo,
      number = issue_number,
      title = "Marketing radar " .. tostring(issue_number),
      url = "https://github.example/" .. repo .. "/issues/" .. tostring(issue_number),
      state = "OPEN",
      labels = { "auto-twitter-marketing" },
      updated_at = "2026-07-28T09:00:0" .. tostring(issue_number % 10) .. "Z",
      source_ref = source_ref(issue_number),
      dedup_key = repo .. "#issue#" .. tostring(issue_number) .. "@2026-07-28T09:00:00Z",
    },
    source_ref = {
      kind = "external",
      reference = repo .. "#issue/" .. tostring(issue_number),
    },
  }
end

local function observed_issue_event(issue_number)
  local event = issue_event(issue_number)
  event.queue = "github-proxy.github_issue_observed"
  event.payload = {
    schema = "github-proxy.issue-observed.v1",
    type = "issue",
    repo = repo,
    number = issue_number,
    updated_at = "2026-07-28T09:00:0" .. tostring(issue_number % 10) .. "Z",
    dedup_key = "github-issue-observed/" .. repo .. "/" .. tostring(issue_number) .. "/probe",
    source = "gh",
    source_ref = source_ref(issue_number),
  }
  return event
end

local function run_issue(issue_number, body, max_steps)
  mock_common_env()
  mock_issue_read(issue_number, body)
  return graph.require_quiescent(graph.run(issue_event(issue_number), { max_steps = max_steps or 10 }))
end

local function run_observed_issue(issue_number, body, max_steps)
  mock_common_env()
  mock_issue_read(issue_number, body)
  return graph.require_quiescent(graph.run(observed_issue_event(issue_number), { max_steps = max_steps or 10 }))
end

return {
  test_radar_config_issue_imports_and_comments_receipt = function()
    local trace = run_issue(51, [[
type: radar-config
project: chronoai
account: example_user
cadence: daily
timezone: Asia/Shanghai
]])

    graph.assert_covers(trace, {
      "github-proxy.github_issue_changed -> marketing-radar.import_issue",
    })

    local imported = graph.require_raise(trace, "marketing-radar.radar_config_imported")
    t.eq(imported.payload.schema, "marketing-radar.config-imported.v1")
    t.eq(imported.payload.project, "chronoai")
    t.eq(imported.payload.source_ref.ref, repo .. "#issue/51")

    local comment = graph.require_raise(trace, "github-proxy.github_issue_comment_request")
    t.is_true(comment.payload.body:find("radar config imported", 1, true) ~= nil)
  end,

  test_radar_signal_issue_imports_signal = function()
    local trace = run_issue(52, [[
type: radar-signal
project: chronoai
week: 2026-W31
topic: FKST hosted automation
source-url: https://github.example/owner/repo/issues/51
insight: GitHub issue inputs can drive publishing.
]])

    local signal = graph.require_raise(trace, "marketing-radar.radar_signal_imported")
    t.eq(signal.payload.schema, "marketing-radar.signal-imported.v1")
    t.eq(signal.payload.project, "chronoai")
    t.eq(signal.payload.topic, "FKST hosted automation")
  end,

  test_radar_run_creates_radar_brief_and_weekly_content_issue_request = function()
    local trace = run_issue(53, [[
type: radar-run
project: chronoai
week: 2026-W31
strategy-ref: #51
topic: FKST hosted automation
source-url: https://github.example/owner/repo/issues/51
insight: Local hosted can import strategy and weekly content issues.
tweet-text:
```
Radar generated test post for FKST auto-twitter.
```
assignee: github-username
]], 12)

    local brief = graph.require_raise(trace, "marketing-radar.radar_brief_created")
    t.eq(brief.payload.schema, "marketing-radar.brief-created.v1")
    t.eq(brief.payload.project, "chronoai")

    local create = graph.require_raise(trace, "github-proxy.github_issue_create_request")
    t.is_true(create.payload.title:find("Radar weekly content", 1, true) ~= nil)
    t.is_true(create.payload.body:find("type: weekly-content", 1, true) ~= nil)
    t.is_true(create.payload.body:find("tweet-text:", 1, true) ~= nil)
    t.eq(create.payload.assignees[1], "github-username")
  end,

  test_radar_run_creates_schedule_issue_request_when_calendar_ref_is_known = function()
    local trace = run_issue(54, [[
type: radar-run
project: chronoai
week: 2026-W31
calendar-ref: #99
mode: shadow
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
assignee: github-username
]], 12)

    local create = graph.require_raise(trace, "github-proxy.github_issue_create_request")
    t.is_true(create.payload.title:find("Radar schedule publish", 1, true) ~= nil)
    t.is_true(create.payload.body:find("type: schedule-publish", 1, true) ~= nil)
    t.is_true(create.payload.body:find("calendar-ref: #99", 1, true) ~= nil)
  end,

  test_observed_radar_run_resync_covers_level_triggered_edge = function()
    local trace = run_observed_issue(55, [[
type: radar-run
project: chronoai
week: 2026-W31
strategy-ref: #51
topic: FKST hosted automation
tweet-text:
```
Observed radar resync generated content.
```
]], 12)

    graph.assert_covers(trace, {
      "github-proxy.github_issue_observed -> marketing-radar.import_issue",
    })

    local create = graph.require_raise(trace, "github-proxy.github_issue_create_request")
    t.is_true(create.payload.body:find("type: weekly-content", 1, true) ~= nil)
  end,
}
