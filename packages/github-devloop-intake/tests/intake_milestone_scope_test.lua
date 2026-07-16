local config = require("devloop.config")
local entity_lib = require("devloop.entity")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local gh_argv = require("testkit.gh_argv_mock")
local h = require("tests.devloop_helpers")
local parsers_issue = require("devloop.parsers.issue")
local t = h.t

local intake_fields = "title,body,createdAt,updatedAt,labels,comments,state,assignees,author,milestone"

local function source_ref(number)
  return entity_lib.issue_source_ref("owner/repo", number)
end

local function entity_changed(number)
  return {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = number,
      title = "Issue " .. tostring(number),
      state = "OPEN",
      labels = {},
      updated_at = "2026-07-16T01:02:03Z",
      dedup_key = "owner/repo#issue#" .. tostring(number) .. "@2026-07-16T01:02:03Z",
      source_ref = source_ref(number),
    },
    source_ref = source_ref(number),
  }
end

local function assignees_json(assignees)
  local rendered = {}
  for _, login in ipairs(assignees or {}) do
    table.insert(rendered, '{"login":"' .. tostring(login) .. '"}')
  end
  return table.concat(rendered, ",")
end

local function issue_view_json(number, milestone_json, assignees)
  return '{"number":' .. tostring(number)
    .. ',"title":"Issue ' .. tostring(number) .. '"'
    .. ',"body":"","createdAt":"2026-07-16T01:00:00Z"'
    .. ',"updatedAt":"2026-07-16T01:02:03Z","state":"OPEN"'
    .. ',"labels":[],"comments":[],"assignees":[' .. assignees_json(assignees) .. ']'
    .. ',"author":{"login":"fkst-test-bot"},"milestone":' .. tostring(milestone_json or "null") .. "}\n"
end

local function mock_env(scope, write_mode)
  h.mock_bot_env()
  for _ = 1, 4 do
    t.mock_command(config.read_env_command("FKST_DEVLOOP_INTAKE_MILESTONE_NUMBERS"), {
      stdout = scope or "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(config.read_env_command("FKST_GITHUB_CLAIM_MODE"), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(config.read_env_command("FKST_GITHUB_WRITE"), {
      stdout = write_mode or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function mock_issue(number, milestone_json, assignees)
  entity_read_mocks.mock_issue_view_raw_selector(t, { number = number }, intake_fields, {
    stdout = issue_view_json(number, milestone_json, assignees),
    stderr = "",
    exit_code = 0,
  })
end

local function run_admission(name, number, scope, milestone_json, assignees, write_mode)
  mock_env(scope, write_mode)
  mock_issue(number, milestone_json, assignees)
  return t.run_department("departments/admission/main.lua", entity_changed(number), h.opts(name, {
    FKST_DEVLOOP_INTAKE_MILESTONE_NUMBERS = scope or "",
    FKST_GITHUB_WRITE = write_mode or "",
  }))
end

local function candidate_for(result, number)
  return h.find_raise(result.raises, "devloop_intake_candidate", function(payload)
    return tostring(payload.issue_number) == tostring(number)
  end)
end

local function count_assign_calls()
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    if gh_argv.call_contains(call, "--add-assignee") then
      count = count + 1
    end
  end
  return count
end

local function config_exec(value)
  return function(command)
    t.eq(command, config.read_env_command("FKST_DEVLOOP_INTAKE_MILESTONE_NUMBERS"))
    return { stdout = value or "", stderr = "", exit_code = 0 }
  end
end

return {
  test_milestone_scope_config_parses_a_strict_positive_integer_set = function()
    t.eq(config.intake_milestone_numbers(config_exec("")), nil)
    local milestones = config.intake_milestone_numbers(config_exec(" 34, 35,34 "))
    t.eq(milestones[34], true)
    t.eq(milestones[35], true)
    t.eq(milestones[36], nil)

    for _, invalid in ipairs({ "0", "-1", "1.5", "milestone-34", ",34", "34,", "34,,35" }) do
      t.raises(function()
        config.intake_milestone_numbers(config_exec(invalid))
      end)
    end
  end,

  test_intake_parser_reads_live_milestone_number_and_rejects_malformed_objects = function()
    local parsed = parsers_issue.parse_issue_view_intake_judge({}, issue_view_json(42, '{"number":34,"title":"M34"}', {}))
    t.eq(parsed.milestone_number, 34)
    t.eq(parsers_issue.parse_issue_view_intake_judge({}, issue_view_json(42, "null", {})).milestone_number, nil)
    t.raises(function()
      parsers_issue.parse_issue_view_intake_judge({}, issue_view_json(42, '{}', {}))
    end)
  end,

  test_initial_claim_accepts_each_configured_milestone = function()
    for _, milestone in ipairs({ 34, 35 }) do
      local number = 2700 + milestone
      local result = run_admission(
        "intake-milestone-accepted-" .. tostring(milestone),
        number,
        "34,35",
        '{"number":' .. tostring(milestone) .. ',"title":"Target"}',
        {},
        ""
      )
      t.eq(result.exit_code, 0)
      t.is_true(candidate_for(result, number) ~= nil)
    end
  end,

  test_initial_claim_rejects_other_or_missing_milestone_before_any_write = function()
    local before = count_assign_calls()
    local outside = run_admission("intake-milestone-outside", 2786, "34,35", '{"number":36,"title":"Other"}', {}, "1")
    local missing = run_admission("intake-milestone-missing", 2785, "34,35", "null", {}, "1")

    t.eq(outside.exit_code, 0)
    t.eq(missing.exit_code, 0)
    t.eq(candidate_for(outside, 2786), nil)
    t.eq(candidate_for(missing, 2785), nil)
    t.eq(count_assign_calls(), before)
  end,

  test_live_membership_revalidation_ignores_stale_event_and_observes_later_change = function()
    local rejected = run_admission("intake-milestone-live-reject", 2784, "34,35", '{"number":36}', {}, "1")
    t.eq(rejected.exit_code, 0)
    t.eq(candidate_for(rejected, 2784), nil)

    local admitted = run_admission("intake-milestone-live-admit", 2784, "34,35", '{"number":34}', {}, "")
    t.eq(admitted.exit_code, 0)
    t.is_true(candidate_for(admitted, 2784) ~= nil)
  end,

  test_self_held_claim_bypasses_initial_scope_after_milestone_changes = function()
    local before = count_assign_calls()
    local result = run_admission(
      "intake-milestone-self-held",
      2784,
      "34,35",
      '{"number":36,"title":"Moved"}',
      { "fkst-test-bot" },
      "1"
    )

    t.eq(result.exit_code, 0)
    t.is_true(candidate_for(result, 2784) ~= nil)
    t.eq(count_assign_calls(), before)
  end,

  test_invalid_scope_fails_closed_before_claim = function()
    local before = count_assign_calls()
    local result = run_admission("intake-milestone-invalid-config", 2784, "34,,35", '{"number":34}', {}, "1")

    t.eq(result.exit_code, 1)
    t.eq(candidate_for(result, 2784), nil)
    t.eq(count_assign_calls(), before)
  end,

  test_pr_events_remain_outside_issue_admission_scope = function()
    mock_env("34,35", "1")
    local event = entity_changed(2800)
    event.payload.type = "pr"
    local result = t.run_department("departments/admission/main.lua", event, h.opts("intake-milestone-pr", {
      FKST_DEVLOOP_INTAKE_MILESTONE_NUMBERS = "34,35",
      FKST_GITHUB_WRITE = "1",
    }))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
