local testing = require("std.testing")
local github_fake = require("std.github_fake")
local core = require("core")
local t = fkst.test

local function opts(name, env)
  local base = {
    FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/archaudit/" .. tostring(name),
    FKST_DURABLE_ROOT = "/tmp/fkst-packages-test/archaudit/durable-" .. tostring(name),
    FKST_GITHUB_REPO = "owner/repo",
    ARCHAUDIT_MAX_ISSUES_PER_IDLE = "3",
    FKST_GITHUB_WRITE = "",
  }
  for key, value in pairs(env or {}) do
    base[key] = value
  end
  return { env = base }
end

local function idle_event(extra)
  local detected_at = "1970-01-01T00:00:00Z"
  local payload = {
    schema = "idle-detector.system-idle.v1",
    detected_at = detected_at,
    expires_at = "1970-01-01T00:10:00Z",
    source_ref = { kind = "host-observe", ref = "idle_tick/" .. detected_at },
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return {
    queue = "idle-detector.system_idle",
    ts = payload.detected_at,
    payload = payload,
  }
end

local function fresh_idle_event()
  return idle_event({
    detected_at = "2026-06-19T01:00:00Z",
    expires_at = "2026-06-19T01:10:00Z",
  })
end

local function stale_idle_event()
  return idle_event({
    detected_at = "2026-06-19T01:00:00Z",
    expires_at = "2026-06-19T01:20:00Z",
  })
end

local function mock_env(repo, max_issues)
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = repo or "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$ARCHAUDIT_MAX_ISSUES_PER_IDLE"', { stdout = max_issues or "3", stderr = "", exit_code = 0 })
end

local function mock_idle_observe()
  t.mock_command('fkst-framework observe --durable-root "$FKST_DURABLE_ROOT" --json', {
    stdout = '{"schema_version":1,"generated_at_ms":1781830860000,"source":{"durable_root":"/tmp/fkst-durable","database":"/tmp/fkst-durable/delivery.redb","read_semantics":"single read transaction","history_semantics":"delivery queue snapshot only"},"limits":{"max_deliveries":500,"max_dead_letters":500},"truncated":{"deliveries":false,"dead_letters":false},"queues":[{"queue":"proposal","depth":0,"pending":0,"in_flight":0,"retrying":0,"oldest_pending_age_ms":null}],"deliveries":[],"dead_letters":[]}',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_busy_observe()
  t.mock_command('fkst-framework observe --durable-root "$FKST_DURABLE_ROOT" --json', {
    stdout = '{"schema_version":1,"generated_at_ms":1781830860000,"source":{"durable_root":"/tmp/fkst-durable","database":"/tmp/fkst-durable/delivery.redb","read_semantics":"single read transaction","history_semantics":"delivery queue snapshot only"},"limits":{"max_deliveries":500,"max_dead_letters":500},"truncated":{"deliveries":false,"dead_letters":false},"queues":[{"queue":"proposal","depth":1,"pending":1,"in_flight":0,"retrying":0,"oldest_pending_age_ms":1000}],"deliveries":[],"dead_letters":[]}',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_observe(stdout, exit_code)
  t.mock_command('fkst-framework observe --durable-root "$FKST_DURABLE_ROOT" --json', {
    stdout = stdout,
    stderr = exit_code == 0 and "" or "observe failed",
    exit_code = exit_code or 0,
  })
end

local function mock_stale_observe()
  mock_observe('{"schema_version":1,"generated_at_ms":1781831461000,"source":{"durable_root":"/tmp/fkst-durable","database":"/tmp/fkst-durable/delivery.redb","read_semantics":"single read transaction","history_semantics":"delivery queue snapshot only"},"limits":{"max_deliveries":500,"max_dead_letters":500},"truncated":{"deliveries":false,"dead_letters":false},"queues":[{"queue":"proposal","depth":0,"pending":0,"in_flight":0,"retrying":0,"oldest_pending_age_ms":null}],"deliveries":[],"dead_letters":[]}', 0)
end

local function mock_codex_findings(stdout, exit_code)
  t.mock_command("codex exec", {
    stdout = stdout,
    stderr = exit_code == 0 and "" or "codex timeout",
    exit_code = exit_code or 0,
  })
end

local function fake_audit_department(label_stdout)
  package.loaded["departments.audit.main"] = nil
  local model = github_fake.model()
  local label_calls = {}
  local github = github_fake.new(model)
  function github.label_list(repo, timeout)
    table.insert(label_calls, { repo = repo, timeout = timeout })
    return { stdout = label_stdout or "[]", stderr = "", exit_code = 0 }
  end
  local installed = require("departments.audit.main")
  t.eq(type(installed.make_department), "function")
  local dept = installed.make_department({ github = github, git = nil })
  dept.model = model
  return dept, model, label_calls
end

local function run_fake_at(dept, event, fixed_now_seconds)
  local previous_now = now
  now = function()
    return fixed_now_seconds
  end
  local ok, result = pcall(testing.run_fake, dept, event)
  now = previous_now
  if not ok then
    error(result, 0)
  end
  return result
end

local function run_fake_failure_at(dept, event, fixed_now_seconds)
  local previous_now = now
  now = function()
    return fixed_now_seconds
  end
  local ok, result = pcall(testing.run_fake_expecting_failure, dept, event)
  now = previous_now
  if not ok then
    error(result, 0)
  end
  return result
end

return {
  test_fake_fresh_idle_codex_finding_raises_issue_create_request = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings('[{"file":"packages/archaudit/core.lua","line":1,"rule":"SRP","why":"Core has one concrete issue.","suggested_fix":"Move the local helper."}]', 0)
    local dept = fake_audit_department("[]")
    local result = run_fake_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github-proxy.github_issue_create_request")
    t.eq(result.raises[1].payload.schema, "github-proxy.issue-create.v1")
    t.eq(result.raises[1].payload.repo, "owner/repo")
    t.eq(#result.raises[1].payload.labels, 0)
    t.eq(result.raises[1].payload.source_ref.kind, "repo-site")
    t.is_true(result.raises[1].payload.body:find("archaudit-dedup: " .. result.raises[1].payload.dedup_key, 1, true) ~= nil)
  end,

  test_fake_caps_distinct_valid_findings_to_first_three = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings(table.concat({
      "[",
      '{"file":"packages/archaudit/core.lua","line":1,"rule":"SRP","why":"First issue.","suggested_fix":"Fix first."}',
      ',{"file":"packages/archaudit/core.lua","line":1,"rule":"DIP","why":"Second issue.","suggested_fix":"Fix second."}',
      ',{"file":"packages/archaudit/core.lua","line":1,"rule":"Demeter","why":"Third issue.","suggested_fix":"Fix third."}',
      ',{"file":"packages/archaudit/core.lua","line":1,"rule":"God-state","why":"Fourth issue.","suggested_fix":"Fix fourth."}',
      "]",
    }, ""), 0)
    local dept = fake_audit_department("[]")
    local result = run_fake_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 3)
    t.eq(result.raises[1].payload.title, "Archaudit: packages/archaudit/core.lua:1 SRP")
    t.eq(result.raises[2].payload.title, "Archaudit: packages/archaudit/core.lua:1 DIP")
    t.eq(result.raises[3].payload.title, "Archaudit: packages/archaudit/core.lua:1 Demeter")
  end,

  test_fake_mixed_valid_plus_invalid_batch_is_all_or_nothing_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings('[{"file":"packages/archaudit/core.lua","line":1,"rule":"SRP","why":"Valid issue.","suggested_fix":"Fix valid."},{"file":"packages/archaudit/core.lua","line":999999,"rule":"DIP","why":"Invalid line.","suggested_fix":"Fix invalid."}]', 0)
    local dept = fake_audit_department("[]")
    local event = fresh_idle_event()
    local result = run_fake_failure_at(dept, event, core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.is_true(tostring(result.failure.error):find("invalid file or line", 1, true) ~= nil)
    t.eq(#result.raises, 0)
  end,

  test_stale_idle_hint_skips_without_codex = function()
    mock_stale_observe()
    local dept = fake_audit_department("[]")
    local result = run_fake_at(dept, stale_idle_event(), core.iso_timestamp_epoch_seconds("1970-01-01T00:00:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_current_busy_skips_without_codex = function()
    mock_env("owner/repo", "3")
    mock_busy_observe()
    local dept = fake_audit_department("[]")
    local result = run_fake_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_current_observe_missing_queues_is_structured_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_observe('{"schema_version":1,"generated_at_ms":1781830860000,"deliveries":[],"dead_letters":[]}', 0)
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_current_observe_unknown_schema_is_structured_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_observe('{"schema_version":2,"generated_at_ms":1781830860000,"queues":[],"deliveries":[],"dead_letters":[]}', 0)
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_current_observe_malformed_top_level_is_structured_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_observe('{"schema_version":1,"generated_at_ms":"1781830860000","queues":[],"deliveries":[],"dead_letters":[]}', 0)
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_current_observe_keyed_lists_are_structured_failure_no_issue = function()
    for _, observe_json in ipairs({
      '{"schema_version":1,"generated_at_ms":1781830860000,"queues":{"proposal":{"depth":0,"pending":0,"in_flight":0,"retrying":0}},"deliveries":[],"dead_letters":[]}',
      '{"schema_version":1,"generated_at_ms":1781830860000,"queues":[{"queue":"proposal","depth":0,"pending":0,"in_flight":0,"retrying":0}],"deliveries":{"one":{}},"dead_letters":[]}',
      '{"schema_version":1,"generated_at_ms":1781830860000,"queues":[{"queue":"proposal","depth":0,"pending":0,"in_flight":0,"retrying":0}],"deliveries":[],"dead_letters":{"one":{}}}',
    }) do
      mock_env("owner/repo", "3")
      mock_observe(observe_json, 0)
      local dept = fake_audit_department("[]")
      local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
      t.eq(#result.raises, 0)
    end
  end,

  test_fake_current_observe_missing_each_busy_dimension_is_structured_failure_no_issue = function()
    for _, observe_json in ipairs({
      '{"schema_version":1,"generated_at_ms":1781830860000,"queues":[{"queue":"proposal","pending":0,"in_flight":0,"retrying":0}],"deliveries":[],"dead_letters":[]}',
      '{"schema_version":1,"generated_at_ms":1781830860000,"queues":[{"queue":"proposal","depth":0,"in_flight":0,"retrying":0}],"deliveries":[],"dead_letters":[]}',
      '{"schema_version":1,"generated_at_ms":1781830860000,"queues":[{"queue":"proposal","depth":0,"pending":0,"retrying":0}],"deliveries":[],"dead_letters":[]}',
      '{"schema_version":1,"generated_at_ms":1781830860000,"queues":[{"queue":"proposal","depth":0,"pending":0,"in_flight":0}],"deliveries":[],"dead_letters":[]}',
    }) do
      mock_env("owner/repo", "3")
      mock_observe(observe_json, 0)
      local dept = fake_audit_department("[]")
      local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
      t.eq(#result.raises, 0)
    end
  end,

  test_fake_current_observe_malformed_queue_rows_are_structured_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_observe('{"schema_version":1,"generated_at_ms":1781830860000,"queues":[{"queue":"","depth":0,"pending":0,"in_flight":0,"retrying":0}],"deliveries":[],"dead_letters":[]}', 0)
    local bad_name_dept = fake_audit_department("[]")
    local bad_name = run_fake_failure_at(bad_name_dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#bad_name.raises, 0)

    mock_env("owner/repo", "3")
    mock_observe('{"schema_version":1,"generated_at_ms":1781830860000,"queues":[{"queue":"proposal","depth":0,"pending":-1,"in_flight":0,"retrying":0}],"deliveries":[],"dead_letters":[]}', 0)
    local negative_dept = fake_audit_department("[]")
    local negative = run_fake_failure_at(negative_dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#negative.raises, 0)
  end,

  test_fake_missing_repo_is_structured_failure_no_issue = function()
    mock_env("", "3")
    mock_idle_observe()
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_long_repo_is_structured_failure_no_issue = function()
    mock_env("owner/" .. string.rep("r", 201), "3")
    mock_idle_observe()
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_malformed_repo_is_structured_failure_no_issue = function()
    mock_env("owner repo", "3")
    mock_idle_observe()
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_malformed_codex_is_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings("not json", 0)
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_timeout_codex_is_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings("", 124)
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_codex_nonzero_is_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings("", 2)
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_codex_non_array_json_is_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings('{"file":"packages/archaudit/core.lua"}', 0)
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_fake_codex_validation_failure_is_failure_no_issue = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings('[{"file":"packages/archaudit/core.lua","line":999999,"rule":"SRP","why":"Bad line.","suggested_fix":"Fix."}]', 0)
    local dept = fake_audit_department("[]")
    local result = run_fake_failure_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 0)
  end,

  test_run_fake_label_present_raises_labeled_issue = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings('[{"file":"packages/archaudit/core.lua","line":1,"rule":"SRP","why":"Concrete issue.","suggested_fix":"Small local fix."}]', 0)
    local dept, model, label_calls = fake_audit_department('[{"name":"archaudit"}]')
    local result = run_fake_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github-proxy.github_issue_create_request")
    t.eq(result.raises[1].payload.labels[1], "archaudit")
    t.eq(#label_calls, 1)
    t.eq(label_calls[1].repo, "owner/repo")
    t.eq(label_calls[1].timeout, 30)
    t.eq(#model.writes, 0)
    t.eq(#result.writes, 0)
  end,

  test_run_fake_label_missing_still_raises_unlabeled_issue = function()
    mock_env("owner/repo", "3")
    mock_idle_observe()
    mock_codex_findings('[{"file":"packages/archaudit/core.lua","line":1,"rule":"SRP","why":"Concrete issue.","suggested_fix":"Small local fix."}]', 0)
    local dept, model, label_calls = fake_audit_department('[{"name":"bug"}]')
    local result = run_fake_at(dept, fresh_idle_event(), core.iso_timestamp_epoch_seconds("2026-06-19T01:01:00Z"))
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "github-proxy.github_issue_create_request")
    t.eq(#result.raises[1].payload.labels, 0)
    t.eq(#label_calls, 1)
    t.eq(label_calls[1].repo, "owner/repo")
    t.eq(label_calls[1].timeout, 30)
    t.eq(#model.writes, 0)
    t.eq(#result.writes, 0)
  end,

  test_malformed_detected_at_is_structured_failure_no_issue = function()
    mock_idle_observe()
    local result = t.run_department("departments/audit/main.lua", idle_event({
      detected_at = "not-a-time",
    }), opts("malformed-detected-at"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
  end,

  test_malformed_expires_at_is_structured_failure_no_issue = function()
    mock_idle_observe()
    local result = t.run_department("departments/audit/main.lua", idle_event({
      expires_at = "not-a-time",
    }), opts("malformed-expires-at"))
    t.eq(result.exit_code, 1)
    t.eq(#result.raises, 0)
  end,
}
