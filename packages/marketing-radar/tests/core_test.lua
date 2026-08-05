local core = require("core")
local issue_create_limits = require("contract.github_issue_create").limits()
local t = fkst.test

local function issue(ref, body)
  local repo, number = ref:match("^([^#]+)#issue/(%d+)$")
  return {
    repo = repo,
    number = tonumber(number),
    title = "untrusted title",
    body = body or "",
    source_ref = { kind = "external", ref = ref },
  }
end

return {
  test_weekly_content_dedup_key_respects_issue_create_contract_boundary = function()
    local key = core.weekly_content_dedup_key({
      ref = string.rep("r", issue_create_limits.source_ref_ref),
    }, {
      ref = "owner/repo#issue/11",
    })

    t.is_true(#key <= issue_create_limits.dedup_key)
  end,

  test_parse_minimal_radar_run_contract = function()
    local parsed = core.parse_radar_run_contract(table.concat({
      "config-ref: owner/repo#issue/10",
      "signal-ref: owner/repo#issue/11",
      "",
    }, "\n"))

    t.eq(parsed.config_source_ref.kind, "external")
    t.eq(parsed.config_source_ref.ref, "owner/repo#issue/10")
    t.eq(parsed.signal_source_ref.ref, "owner/repo#issue/11")
  end,

  test_calendar_ref_is_outside_this_walking_skeleton = function()
    local parsed, reason = core.parse_radar_run_contract(table.concat({
      "config-ref: owner/repo#issue/10",
      "signal-ref: owner/repo#issue/11",
      "calendar-ref: owner/repo#issue/12",
    }, "\n"))

    t.eq(parsed, nil)
    t.eq(reason, "calendar-ref-present")
  end,

  test_weekly_content_request_and_receipt_copy_only_source_pointers = function()
    local run = issue("owner/repo#issue/20", table.concat({
      "config-ref: owner/repo#issue/10",
      "signal-ref: owner/repo#issue/11",
      "",
      "api_key = should-not-copy",
      string.rep("long-source-body ", 40),
    }, "\n"))
    local config = issue("owner/repo#issue/10", "credential=should-not-copy")
    local signal = issue("owner/repo#issue/11", "secret-signal-body should-not-copy")

    local outputs = core.build_weekly_content_outputs(run, config, signal)

    t.eq(outputs.request.schema, "github-proxy.issue-create.v1")
    t.eq(outputs.request.repo, "owner/repo")
    t.eq(outputs.request.title, "weekly-content: marketing-radar skeleton")
    t.eq(outputs.request.labels[1], "auto-twitter-marketing")
    t.eq(outputs.request.source_ref.ref, "owner/repo#issue/20")
    t.is_true(outputs.request.dedup_key:find("marketing-radar/weekly-content/", 1, true) == 1)
    t.is_true(outputs.request.body:find("owner/repo#issue/20", 1, true) ~= nil)
    t.is_true(outputs.request.body:find("owner/repo#issue/10", 1, true) ~= nil)
    t.is_true(outputs.request.body:find("owner/repo#issue/11", 1, true) ~= nil)
    t.is_true(outputs.request.body:find("should-not-copy", 1, true) == nil)
    t.is_true(outputs.request.body:find("long-source-body", 1, true) == nil)

    t.eq(outputs.receipt.schema, "marketing-radar.weekly-content-generated.v1")
    t.eq(outputs.receipt.run_source_ref.ref, "owner/repo#issue/20")
    t.eq(outputs.receipt.config_source_ref.ref, "owner/repo#issue/10")
    t.eq(outputs.receipt.signal_source_ref.ref, "owner/repo#issue/11")
    t.eq(outputs.receipt.issue_create_dedup_key, outputs.request.dedup_key)
  end,
}
