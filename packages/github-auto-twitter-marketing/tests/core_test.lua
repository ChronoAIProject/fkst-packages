local core = require("core")
local t = fkst.test

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#issue/42",
  }
end

local function issue(overrides)
  local payload = {
    schema = "github-proxy.v1",
    type = "issue",
    repo = "owner/repo",
    number = 42,
    title = "Auto Twitter marketing",
    url = "https://github.example/owner/repo/issues/42",
    state = "OPEN",
    labels = { "auto-twitter-marketing" },
    updated_at = "2026-07-24T09:00:00Z",
    source_ref = source_ref(),
    dedup_key = "owner/repo#issue#42@2026-07-24T09:00:00Z",
  }
  for key, value in pairs(overrides or {}) do
    payload[key] = value
  end
  return payload
end

return {
  test_parse_control_fields_accepts_issue_body_contract = function()
    local fields = core.parse_control_fields([[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
scheduled-at: 2026-07-25T09:00:00Z
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
]])

    t.eq(fields.type, "schedule-publish")
    t.eq(fields.project, "chronoai")
    t.eq(fields.week, "2026-W31")
    t.eq(fields["calendar-ref"], "#124")
    t.eq(fields.mode, "shadow")
    t.eq(fields["scheduled-at"], "2026-07-25T09:00:00Z")
    t.eq(fields.recurrence, "daily")
    t.eq(fields.time, "11:10")
    t.eq(fields.timezone, "Asia/Shanghai")
  end,

  test_classify_strategy_issue_from_body = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: strategy
project: chronoai
account: main
]],
    })

    t.eq(classified.kind, "strategy")
    t.eq(classified.project, "chronoai")
    t.eq(classified.account, "main")
    t.eq(classified.source_ref.ref, "owner/repo#issue/42")
    t.eq(classified.trace_id, "github:auto-twitter-marketing:owner/repo#issue/42")
  end,

  test_classify_weekly_content_issue_from_controls = function()
    local classified = core.classify_issue(issue({
      body = nil,
      controls = {
        type = "weekly-content",
        project = "chronoai",
        week = "2026-W31",
        ["strategy-ref"] = "#123",
      },
    }))

    t.eq(classified.kind, "weekly-content")
    t.eq(classified.project, "chronoai")
    t.eq(classified.week, "2026-W31")
    t.eq(classified.strategy_ref, "#123")
    t.eq(classified.source_ref.ref, "owner/repo#issue/42")
  end,

  test_classify_can_use_fetched_issue_body_without_payload_body = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: strategy
project: chronoai
account: main
]],
    })

    t.eq(classified.kind, "strategy")
    t.eq(classified.project, "chronoai")
    t.eq(classified.source_ref.ref, "owner/repo#issue/42")
  end,

  test_classify_requires_work_label = function()
    local classified = core.classify_issue(issue({ labels = { "other" } }), {
      issue_body = "type: strategy\nproject: chronoai\naccount: main\n",
    })
    t.is_nil(classified)
  end,

  test_schedule_publish_builds_pointer_only_x_request = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
scheduled-at: 2026-07-25T09:00:00Z
]],
    })
    local request = core.x_publish_request(classified)

    t.eq(request.artifact_id, "auto-twitter-marketing/chronoai/2026-W31/schedule")
    t.eq(request.platform, "x")
    t.eq(request.channel, "shadow")
    t.eq(request.source_ref.ref, "owner/repo#issue/42")
    t.eq(request.scheduled_at, "2026-07-25T09:00:00Z")
    t.eq(request.metadata.campaign_id, "chronoai")
    t.eq(request.metadata.content_type, "weekly-content")
    t.eq(request.metadata.tag, "calendar:#124")
    t.is_nil(request.body)
    t.is_nil(request.text)
    t.is_nil(request.token)
  end,

  test_one_shot_schedule_waits_until_scheduled_at = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
scheduled-at: 2026-07-25T09:00:00Z
]],
    })

    local before = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-25T08:59:59Z"))
    local at_time = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-25T09:00:00Z"))

    t.eq(before.due, false)
    t.eq(before.reason, "not due")
    t.eq(at_time.due, true)
    t.eq(at_time.occurrence_id, "2026-07-25T09:00:00Z")
  end,

  test_daily_schedule_uses_timezone_local_occurrence = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
recurrence: daily
time: 11:10
timezone: Asia/Shanghai
]],
    })

    local before = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-28T03:09:59Z"))
    local due = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-28T03:10:00Z"))
    local request = core.x_publish_request(classified, nil, due)

    t.eq(classified.recurrence, "daily")
    t.eq(before.due, false)
    t.eq(due.due, true)
    t.eq(due.scheduled_at, "2026-07-28T11:10:00+08:00")
    t.eq(due.occurrence_id, "2026-07-28T11:10:00+08:00")
    t.eq(request.scheduled_at, "2026-07-28T11:10:00+08:00")
    t.eq(request.metadata.schedule_type, "daily")
    t.eq(request.metadata.occurrence_id, "2026-07-28T11:10:00+08:00")
    t.is_true(request.dedup_key:find("2026-07-28T11-10-00-08-00", 1, true) ~= nil)
  end,

  test_every_minutes_schedule_uses_anchor_and_interval_occurrence = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: shadow
recurrence: every-minutes
interval-minutes: 10
scheduled-at: 2026-07-29T10:50:00+08:00
]],
    })

    local before = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-29T10:49:59+08:00"))
    local first = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-29T10:50:00+08:00"))
    local second_window = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-29T11:04:59+08:00"))
    local second = core.schedule_decision(classified, core.parse_iso8601_seconds("2026-07-29T11:00:00+08:00"))
    local request = core.x_publish_request(classified, nil, second)

    t.eq(classified.recurrence, "every-minutes")
    t.eq(classified.interval_minutes, 10)
    t.eq(before.due, false)
    t.eq(before.scheduled_at, "2026-07-29T10:50:00+08:00")
    t.eq(first.due, true)
    t.eq(first.occurrence_id, "2026-07-29T10:50:00+08:00")
    t.eq(second_window.occurrence_id, "2026-07-29T11:00:00+08:00")
    t.eq(second.occurrence_id, "2026-07-29T11:00:00+08:00")
    t.eq(request.scheduled_at, "2026-07-29T11:00:00+08:00")
    t.eq(request.metadata.schedule_type, "every-minutes")
    t.eq(request.metadata.interval_minutes, 10)
    t.eq(request.metadata.occurrence_id, "2026-07-29T11:00:00+08:00")
  end,

  test_daily_schedule_requires_explicit_timezone = function()
    local classified, why = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
recurrence: daily
time: 11:10
]],
    })

    t.is_nil(classified)
    t.eq(why, "missing recurring schedule fields")
  end,

  test_live_publish_requires_nyxid_service_gate = function()
    local classified = core.classify_issue(issue(), {
      issue_body = [[
type: schedule-publish
project: chronoai
week: 2026-W31
calendar-ref: #124
mode: live
scheduled-at: 2026-07-25T09:00:00Z
]],
    })

    t.eq(core.live_gate(classified, {}), false)
    t.eq(core.live_gate(classified, { nyxid_x_service = "x-main" }), false)
    t.eq(core.live_gate(classified, { live_write_enabled = true }), false)
    t.eq(core.live_gate(classified, { nyxid_x_service = "x-main", live_write_enabled = true }), true)
  end,
}
