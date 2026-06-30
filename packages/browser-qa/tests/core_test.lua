local core = require("core")
local t = fkst.test

local function source_ref()
  return {
    kind = "external",
    ref = "owner/repo#pull/42/head/abc123",
  }
end

local function request(extra)
  local payload = {
    schema = "browser-qa.request.v1",
    request_id = "browser-qa/pr/owner/repo/42/abc123",
    dedup_key = "browser-qa/pr/owner/repo/42/abc123",
    runner = "playwright",
    target_url = "http://127.0.0.1:4173",
    report_artifact = "browser-qa/owner/repo/42/abc123/report.json",
    source_ref = source_ref(),
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return payload
end

return {
  test_valid_request_keeps_only_small_control_fields = function()
    local normalized = core.normalize_request(request())

    t.eq(normalized.schema, "browser-qa.request.v1")
    t.eq(normalized.runner, "playwright")
    t.eq(normalized.target_url, "http://127.0.0.1:4173")
    t.eq(normalized.report_artifact, "browser-qa/owner/repo/42/abc123/report.json")
    t.eq(normalized.source_ref.kind, "external")
    t.eq(normalized.source_ref.ref, "owner/repo#pull/42/head/abc123")
    t.eq(normalized.argv, nil)
    t.eq(normalized.body, nil)
    t.eq(normalized.diff, nil)
  end,

  test_request_rejects_untrusted_command_or_content_fields = function()
    for _, field in ipairs({ "argv", "command", "cmd", "body", "diff", "content", "files" }) do
      local payload = request({ [field] = "malicious" })
      local ok, err = pcall(function()
        core.normalize_request(payload)
      end)
      t.eq(ok, false)
      t.is_true(tostring(err):find("browser-qa: validation: forbidden-request-field", 1, true) ~= nil)
    end
  end,

  test_request_requires_loopback_target_and_bounded_source_ref = function()
    local ipv6 = core.normalize_request(request({ target_url = "http://[::1]:4173" }))
    t.eq(ipv6.target_url, "http://[::1]:4173")

    t.raises(function()
      core.normalize_request(request({ target_url = "https://example.com" }))
    end)
    t.raises(function()
      core.normalize_request(request({ target_url = "http://192.168.1.10:4173" }))
    end)
    t.raises(function()
      core.normalize_request(request({ target_url = "http://[::1]@example.com:4173" }))
    end)
    t.raises(function()
      core.normalize_request(request({ source_ref = { kind = "external", ref = "" } }))
    end)
  end,

  test_runner_config_comes_from_trusted_environment = function()
    local config = core.runner_config({
      BROWSER_QA_RUNNER = "playwright",
      BROWSER_QA_COMMAND = "npx playwright test --reporter=json",
      BROWSER_QA_TIMEOUT_SECONDS = "90",
      BROWSER_QA_WORKDIR = ".",
    })

    t.eq(config.runner, "playwright")
    t.eq(config.timeout_seconds, 90)
    t.eq(config.workdir, ".")
    t.eq(config.argv[1], "npx")
    t.eq(config.argv[2], "playwright")
    t.eq(config.argv[3], "test")
    t.eq(config.argv[4], "--reporter=json")
    t.eq(config.argv[5], nil)
  end,

  test_runner_config_rejects_shell_metacharacters = function()
    for _, command in ipairs({
      "npx playwright test; rm -rf .",
      "npx playwright test && echo bad",
      "npx playwright test | cat",
      "npx playwright test $(echo bad)",
    }) do
      t.raises(function()
        core.runner_config({
          BROWSER_QA_RUNNER = "playwright",
          BROWSER_QA_COMMAND = command,
        })
      end)
    end
  end,

  test_result_payload_preserves_source_ref_and_classifies_exit = function()
    local result = core.result_payload(request(), {
      exit_code = 1,
      stdout = '{"stats":{"unexpected":1}}',
      stderr = "one failed",
      timed_out = false,
    }, 90)

    t.eq(result.schema, "browser-qa.result.v1")
    t.eq(result.request_id, "browser-qa/pr/owner/repo/42/abc123")
    t.eq(result.decision, "fail")
    t.eq(result.runner, "playwright")
    t.eq(result.exit_code, 1)
    t.eq(result.timed_out, false)
    t.eq(result.report_artifact, "browser-qa/owner/repo/42/abc123/report.json")
    t.eq(result.source_ref.kind, "external")
    t.eq(result.source_ref.ref, "owner/repo#pull/42/head/abc123")
    t.eq(result.stdout_summary, '{"stats":{"unexpected":1}}')
    t.eq(result.stderr_summary, "one failed")
  end,
}
