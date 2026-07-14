local report = require("report_logic")
local core = require("core")
local t = fkst.test

local function usage_json()
  return '{"summary":"Two merged PRs implementing the dashboard.","total_units":90,'
    .. '"line_items":[{"area":"PR #42","units":60},{"area":"PR #43","units":30}]}'
end

return {
  test_parse_usage_accepts_a_valid_object = function()
    local usage = report.parse_usage(usage_json())
    t.eq(usage.total_units, 90)
    t.eq(#usage.line_items, 2)
    t.eq(usage.line_items[1].area, "PR #42")
    t.eq(usage.line_items[1].units, 60)
  end,

  test_parse_usage_rejects_array_or_bad_fields = function()
    t.raises(function()
      report.parse_usage("[]")
    end)
    t.raises(function()
      report.parse_usage('{"summary":"x","total_units":-1,"line_items":[]}')
    end)
    t.raises(function()
      report.parse_usage('{"summary":"x","total_units":5,"line_items":[{"area":"a","units":-2}]}')
    end)
  end,

  test_report_issue_request_maps_with_both_labels = function()
    local usage = report.parse_usage(usage_json())
    local request = report.report_issue_request("owner/repo", usage, "2026-06-19", nil)

    t.eq(request.schema, "github-proxy.issue-create.v1")
    t.eq(request.repo, "owner/repo")
    t.is_true(request.title:find("Finance report", 1, true) ~= nil)
    t.is_true(request.body:find("PR #42", 1, true) ~= nil)

    local labels = {}
    for _, label in ipairs(request.labels) do
      labels[label] = true
    end
    t.is_true(labels["fkst-company"])
    t.is_true(labels["fkst-finance"])
  end,

  test_over_budget_marks_alert_title = function()
    local usage = report.parse_usage(usage_json())
    t.is_true(report.over_budget(usage.total_units, 50))
    t.is_true(not report.over_budget(usage.total_units, 200))
    local request = report.report_issue_request("owner/repo", usage, "2026-06-19", 50)
    t.is_true(request.title:find("budget alert", 1, true) ~= nil)
  end,

  test_window_dedup_key_is_stable = function()
    t.eq(
      report.window_dedup_key("owner/repo", "2026-06-19"),
      report.window_dedup_key("owner/repo", "2026-06-19")
    )
  end,

  test_conformance_errors_is_empty = function()
    t.eq(#core.conformance_errors(), 0)
  end,
}
