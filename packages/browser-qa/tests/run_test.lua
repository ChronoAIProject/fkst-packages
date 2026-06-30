local testing = require("testkit.testing")
local run_department = require("departments.run.main")
local t = fkst.test

local function request(extra)
  local payload = {
    schema = "browser-qa.request.v1",
    request_id = "browser-qa/pr/owner/repo/42/abc123",
    dedup_key = "browser-qa/pr/owner/repo/42/abc123",
    runner = "playwright",
    target_url = "http://127.0.0.1:4173",
    report_artifact = "browser-qa/owner/repo/42/abc123/report.json",
    source_ref = {
      kind = "external",
      ref = "owner/repo#pull/42/head/abc123",
    },
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return payload
end

local function event(payload)
  return {
    queue = "browser-qa.browser_qa_request",
    payload = payload or request(),
  }
end

local function fake_dept(exit_code)
  local calls = {}
  local env = {
    BROWSER_QA_RUNNER = "playwright",
    BROWSER_QA_COMMAND = "npx playwright test --reporter=json",
    BROWSER_QA_TIMEOUT_SECONDS = "90",
    BROWSER_QA_WORKDIR = ".",
  }
  local dept = run_department.make_department({
    read_env = function(name)
      return env[name]
    end,
    exec_argv = function(spec)
      table.insert(calls, spec)
      return {
        stdout = '{"ok":true}',
        stderr = "",
        exit_code = exit_code or 0,
      }
    end,
  })
  dept.calls = calls
  return dept
end

return {
  test_browser_qa_request_runs_trusted_playwright_command_and_raises_result = function()
    local dept = fake_dept(0)

    local result = testing.run_fake(dept, event())

    t.eq(#dept.calls, 1)
    t.eq(dept.calls[1].argv[1], "npx")
    t.eq(dept.calls[1].argv[2], "playwright")
    t.eq(dept.calls[1].argv[3], "test")
    t.eq(dept.calls[1].argv[4], "--reporter=json")
    t.eq(dept.calls[1].timeout, 90)
    t.eq(dept.calls[1].cwd, ".")
    t.eq(dept.calls[1].env.BROWSER_QA_TARGET_URL, "http://127.0.0.1:4173")
    t.eq(dept.calls[1].env.BROWSER_QA_REPORT_ARTIFACT, "browser-qa/owner/repo/42/abc123/report.json")
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "browser_qa_result")
    t.eq(result.raises[1].payload.schema, "browser-qa.result.v1")
    t.eq(result.raises[1].payload.decision, "pass")
    t.eq(result.raises[1].payload.source_ref.ref, "owner/repo#pull/42/head/abc123")
  end,

  test_browser_qa_failure_is_a_result_event_not_a_thrown_error = function()
    local dept = fake_dept(1)

    local result = testing.run_fake(dept, event())

    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "browser_qa_result")
    t.eq(result.raises[1].payload.decision, "fail")
    t.eq(result.raises[1].payload.exit_code, 1)
  end,

  test_payload_argv_is_ignored_and_rejected_before_exec = function()
    local dept = fake_dept(0)
    local result = testing.run_fake_expecting_failure(dept, event(request({
      argv = { "sh", "-c", "echo bad" },
    })))

    t.is_true(
      tostring(result.failure.error):find("browser-qa: validation: forbidden-request-field", 1, true) ~= nil
    )
    t.eq(#dept.calls, 0)
    t.eq(#result.raises, 0)
  end,
}
