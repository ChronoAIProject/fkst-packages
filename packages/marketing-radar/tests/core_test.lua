local core = require("core")
local t = fkst.test

local function source_ref(issue_number)
  local ref = "owner/repo#issue/" .. tostring(issue_number or 42)
  return {
    kind = "external",
    ref = ref,
    reference = ref,
  }
end

local function issue(overrides)
  local payload = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    title = "Marketing radar",
    url = "https://github.example/owner/repo/issues/42",
    state = "OPEN",
    labels = { "auto-twitter-marketing" },
    updated_at = "2026-07-28T09:00:00Z",
    source_ref = source_ref(42),
    dedup_key = "owner/repo#issue#42@2026-07-28T09:00:00Z",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

return {
  test_parse_control_fields_accepts_radar_issue_contract = function()
    local fields = core.parse_control_fields([[
type: radar-run
project: chronoai
week: 2026-W31
strategy-ref: #24
topic: FKST hosted automation
source-url: https://github.com/OWNER/CONTENT_REPO/issues/24
insight: Local hosted can import issues and schedule X posts.
assignee: github-username
output: weekly-content
time: 11:10
timezone: Asia/Shanghai
mode: shadow
]])

    t.eq(fields.type, "radar-run")
    t.eq(fields.project, "chronoai")
    t.eq(fields.week, "2026-W31")
    t.eq(fields["strategy-ref"], "#24")
    t.eq(fields.topic, "FKST hosted automation")
    t.eq(fields["source-url"], "https://github.com/OWNER/CONTENT_REPO/issues/24")
    t.eq(fields.assignee, "github-username")
  end,

  test_classify_radar_config_is_pointer_only = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: radar-config
project: chronoai
account: example_user
cadence: daily
timezone: Asia/Shanghai
]],
    })

    t.eq(classified.kind, "radar-config")
    t.eq(classified.project, "chronoai")
    t.eq(classified.account, "example_user")
    t.eq(classified.source_ref.ref, "owner/repo#issue/42")
    t.eq(classified.trace_id, "github:marketing-radar:owner/repo#issue/42")
    t.is_nil(classified.token)
    t.is_nil(classified.secret)
  end,

  test_classify_radar_signal_requires_label_and_project = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: radar-signal
project: chronoai
week: 2026-W31
topic: FKST hosted automation
insight: GitHub issue inputs can drive publishing.
]],
    })
    t.eq(classified.kind, "radar-signal")
    t.eq(classified.project, "chronoai")

    local missing_label = core.classify_issue(issue({ labels = { "other" } }), {
      issue_body = "type: radar-signal\nproject: chronoai\n",
    })
    t.is_nil(missing_label)
  end,

  test_radar_run_builds_weekly_content_issue_request = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: radar-run
project: chronoai
week: 2026-W31
strategy-ref: #24
topic: FKST hosted automation
source-url: https://github.com/OWNER/CONTENT_REPO/issues/24
insight: Local hosted can import strategy and weekly content issues.
tweet-text:
```
Radar generated test post for FKST auto-twitter.
```
assignee: github-username
]],
    })
    local request = core.weekly_content_issue_request(classified)

    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.eq(request.repo, "owner/repo")
    t.eq(request.labels[1], "auto-twitter-marketing")
    t.eq(request.assignees[1], "github-username")
    t.is_true(request.body:find("type: weekly-content", 1, true) ~= nil)
    t.is_true(request.body:find("strategy-ref: #24", 1, true) ~= nil)
    t.is_true(request.body:find("Radar generated test post for FKST auto-twitter.", 1, true) ~= nil)
    t.is_true(request.dedup_key:find("/weekly-content", 1, true) ~= nil)
    t.eq(request.source_ref.ref, "owner/repo#issue/42")
  end,

  test_radar_run_builds_schedule_issue_request_when_calendar_ref_is_known = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: radar-run
project: chronoai
week: 2026-W31
calendar-ref: #25
mode: live
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
assignee: github-username
]],
    })
    local request = core.schedule_issue_request(classified)

    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.is_true(request.body:find("type: schedule-publish", 1, true) ~= nil)
    t.is_true(request.body:find("calendar-ref: #25", 1, true) ~= nil)
    t.is_true(request.body:find("mode: live", 1, true) ~= nil)
    t.is_true(request.body:find("time: 11:10", 1, true) ~= nil)
    t.eq(request.assignees[1], "github-username")
  end,
}
