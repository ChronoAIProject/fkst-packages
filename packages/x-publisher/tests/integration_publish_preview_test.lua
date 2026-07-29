local t = fkst.test

local repo = "owner/repo"
local run_counter = 0

local function unique_root(label)
  run_counter = run_counter + 1
  return "/tmp/fkst-marketing-test/x-publisher/" .. tostring(label)
    .. "-" .. tostring(now()) .. "-" .. tostring(run_counter)
end

local function event(payload)
  return {
    queue = "x_publish_request",
    payload = payload,
  }
end

local function run_publish(payload, env)
  local env_values = env or {}
  t.mock_command('printf %s "$X_PUBLISH_WRITE"', {
    stdout = env_values.X_PUBLISH_WRITE or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_X_PUBLISH_WRITE"', {
    stdout = env_values.FKST_X_PUBLISH_WRITE or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$NYXID_X_SERVICE_SLUG"', {
    stdout = env_values.NYXID_X_SERVICE_SLUG or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_NYXID_X_SERVICE_SLUG"', {
    stdout = env_values.FKST_NYXID_X_SERVICE_SLUG or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$X_PUBLISH_EXPECTED_USERNAME"', {
    stdout = env_values.X_PUBLISH_EXPECTED_USERNAME or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_X_PUBLISH_EXPECTED_USERNAME"', {
    stdout = env_values.FKST_X_PUBLISH_EXPECTED_USERNAME or "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi', {
    stdout = env_values.NYXID_ACCESS_TOKEN and "1" or "0",
    stderr = "",
    exit_code = 0,
  })
  return t.run_department("departments/publish_x/main.lua", event(payload), {
    env = {
      FKST_RUNTIME_ROOT = unique_root("preview-rt"),
      FKST_DURABLE_ROOT = unique_root("preview-durable"),
    },
  })
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
    '{"number":%d,"title":"Auto Twitter marketing content %d","body":"%s","html_url":"https://github.example/%s/issues/%d","updated_at":"2026-07-24T09:00:00Z","state":"open","labels":[{"name":"auto-twitter-marketing"}],"assignees":[],"user":{"login":"fkst-test-bot"}}\n',
    issue_number,
    issue_number,
    json_escape(body),
    repo,
    issue_number
  )
end

local function mock_author_env()
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
end

local function mock_content_issue(issue_number, body)
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

local function mock_nyxid_cli_available()
  t.mock_command("nyxid --version", {
    stdout = "nyxid 0.8.0\n",
    stderr = "",
    exit_code = 0,
  })
end

local function count_calls(needle)
  local count = 0
  for _, call in ipairs(t.command_calls()) do
    local rendered = tostring(call.rendered or call.command or call.cmd or "")
    if rendered == "" and type(call.argv) == "table" then
      rendered = table.concat(call.argv, " ")
    end
    if rendered:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

return {
  test_publish_request_raises_preview_receipt = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "drafts/artifact-1" },
      content_ref = "#42",
      platform = "x",
      channel = "main",
      dedup_key = "dedup-1",
      trace_id = "trace-1",
      approval_id = "approval-1",
      scheduled_at = "2026-06-24T12:00:00Z",
      metadata = { campaign_id = "campaign-1", locale = "en-US", variant = "a" },
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)

    local raised = result.raises[1]
    t.eq(raised.queue, "x_published")
    t.eq(raised.payload.artifact_id, "artifact-1")
    t.eq(raised.payload.platform, "x")
    t.eq(raised.payload.status, "preview")
    t.is_nil(raised.payload.post_uri)
    t.eq(raised.payload.source_ref.ref, "drafts/artifact-1")
    t.eq(raised.payload.dedup_key, "dedup-1")
    t.eq(raised.payload.trace_id, "trace-1")
    t.eq(raised.payload.approval_id, "approval-1")
    t.eq(raised.payload.metadata.campaign_id, "campaign-1")
    t.eq(raised.payload.content_ref, "#42")
  end,

  test_publish_request_skips_invalid_content_payload = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "draft", ref = "drafts/artifact-1" },
      text = "content must stay behind source_ref",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_live_publish_fails_closed_without_write_gate = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-missing-gate",
      trace_id = "trace-1",
    }, {
      FKST_X_PUBLISH_WRITE = "",
      FKST_NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      FKST_X_PUBLISH_EXPECTED_USERNAME = "example_user",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "x_published")
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "live gate disabled")
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_fails_closed_without_nyxid_access_token = function()
    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-missing-token",
      trace_id = "trace-1",
    }, {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      X_PUBLISH_EXPECTED_USERNAME = "example_user",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "x_published")
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid access token missing")
    t.eq(count_calls("nyxid --version"), 0)
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_fails_closed_without_nyxid_cli = function()
    t.mock_command("nyxid --version", {
      stdout = "",
      stderr = "nyxid: command not found",
      exit_code = 127,
    })

    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-missing-cli",
      trace_id = "trace-1",
    }, {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      X_PUBLISH_EXPECTED_USERNAME = "example_user",
      ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    t.eq(result.raises[1].queue, "x_published")
    t.eq(result.raises[1].payload.status, "blocked")
    t.eq(result.raises[1].payload.blocked_reason, "nyxid cli unavailable")
    t.eq(count_calls('printf %s "$NYXID_ACCESS_TOKEN"'), 0)
    t.eq(count_calls("nyxid proxy request"), 0)
  end,

  test_live_publish_accepts_non_reserved_environment_names = function()
    mock_author_env()
    mock_content_issue(42, [[
type: weekly-content
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
]])
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for example_user via NyxID. Test post."}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-env",
      trace_id = "trace-1",
    }, {
      X_PUBLISH_WRITE = "1",
      NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      X_PUBLISH_EXPECTED_USERNAME = "example_user",
      ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "published")
    t.eq(receipt.platform_post_id, "1234567890123456789")
    t.eq(receipt.account_username, "example_user")
  end,

  test_live_publish_uses_nyxid_after_account_preflight_and_calendar_ref_resolution = function()
    mock_author_env()
    mock_content_issue(42, [[
type: weekly-content
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
]])
    mock_nyxid_cli_available()
    t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
      stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
      stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for example_user via NyxID. Test post."}}',
      stderr = "",
      exit_code = 0,
    })

    local result = run_publish({
      artifact_id = "artifact-1",
      source_ref = { kind = "external", ref = repo .. "#issue/43" },
      content_ref = "#42",
      platform = "x",
      channel = "live",
      dedup_key = "dedup-live-calendar",
      trace_id = "trace-1",
    }, {
      FKST_X_PUBLISH_WRITE = "1",
      FKST_NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
      FKST_X_PUBLISH_EXPECTED_USERNAME = "example_user",
      ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
    })

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 1)
    local receipt = result.raises[1].payload
    t.eq(receipt.status, "published")
    t.eq(receipt.platform_post_id, "1234567890123456789")
    t.eq(receipt.post_uri, "https://x.com/i/web/status/1234567890123456789")
    t.eq(receipt.account_username, "example_user")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET"), 1)
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,

  test_live_publish_duplicate_dedup_key_skips_second_post = function()
    local suffix = tostring(now())
    local runtime_root = "/tmp/fkst-marketing-test/x-publisher/live-once-" .. suffix
    local durable_root = "/tmp/fkst-marketing-test/x-publisher/live-once-durable-" .. suffix
    local dedup_key = "dedup-live-once-" .. suffix
    local function run_once()
      mock_author_env()
      mock_content_issue(42, [[
type: weekly-content
week: 2026-W31

tweet-text:
```
FKST live publish verification for example_user via NyxID. Test post.
```
]])
      mock_nyxid_cli_available()
      t.mock_command("nyxid proxy request api-twitter-2-media '/users/me?user.fields=id,name,username' -m GET", {
        stdout = '{"data":{"id":"100000000000000001","name":"Example User","username":"example_user"}}',
        stderr = "",
        exit_code = 0,
      })
      t.mock_command("nyxid proxy request api-twitter-2-media /tweets -m POST", {
        stdout = '{"data":{"id":"1234567890123456789","text":"FKST live publish verification for example_user via NyxID. Test post."}}',
        stderr = "",
        exit_code = 0,
      })
      local env_values = {
        FKST_X_PUBLISH_WRITE = "1",
        FKST_NYXID_X_SERVICE_SLUG = "api-twitter-2-media",
        FKST_X_PUBLISH_EXPECTED_USERNAME = "example_user",
        ["NYXID_ACCESS_TOKEN"] = "test-agent-key",
      }
      t.mock_command('printf %s "$X_PUBLISH_WRITE"', { stdout = "", stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$FKST_X_PUBLISH_WRITE"', { stdout = env_values.FKST_X_PUBLISH_WRITE, stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$NYXID_X_SERVICE_SLUG"', { stdout = "", stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$FKST_NYXID_X_SERVICE_SLUG"', { stdout = env_values.FKST_NYXID_X_SERVICE_SLUG, stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$X_PUBLISH_EXPECTED_USERNAME"', { stdout = "", stderr = "", exit_code = 0 })
      t.mock_command('printf %s "$FKST_X_PUBLISH_EXPECTED_USERNAME"', { stdout = env_values.FKST_X_PUBLISH_EXPECTED_USERNAME, stderr = "", exit_code = 0 })
      t.mock_command('if [ -n "$NYXID_ACCESS_TOKEN" ]; then printf 1; else printf 0; fi', { stdout = "1", stderr = "", exit_code = 0 })
      return t.run_department("departments/publish_x/main.lua", event({
        artifact_id = "artifact-once",
        source_ref = { kind = "external", ref = repo .. "#issue/43" },
        content_ref = "#42",
        platform = "x",
        channel = "live",
        dedup_key = dedup_key,
        trace_id = "trace-once",
      }), {
        env = {
          FKST_RUNTIME_ROOT = runtime_root,
          FKST_DURABLE_ROOT = durable_root,
        },
      })
    end

    local first = run_once()
    local second = run_once()

    t.eq(first.exit_code, 0)
    t.eq(second.exit_code, 0)
    t.eq(first.raises[1].payload.status, "published")
    t.eq(second.raises[1].payload.status, "skipped")
    t.eq(count_calls("nyxid proxy request api-twitter-2-media /tweets -m POST"), 1)
  end,
}
