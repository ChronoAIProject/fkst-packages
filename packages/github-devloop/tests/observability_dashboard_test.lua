local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core
local unpack_results = table.unpack or unpack

local function mock_env(write_mode)
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = write_mode or "1",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, 8 do
    t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
      stdout = "fkst-test-bot",
      stderr = "",
      exit_code = 0,
    })
  end
  for _, name in ipairs({ "GH_TOKEN", "GITHUB_TOKEN" }) do
    t.mock_command('if [ -n "${' .. name .. ':-}" ]; then printf present; fi', {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function encode_body(value)
  return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function dashboard_issue_list_stdout(body)
  if body == nil then
    return "[[]]\n"
  end
  return '[[{"number":99,"title":"fkst-dev board","user":{"login":"fkst-test-bot"},"body":"'
    .. encode_body(body)
    .. '"}]]\n'
end

local function dashboard_issue_list_stdout_many(bodies)
  local items = {}
  for index, body in ipairs(bodies or {}) do
    table.insert(items, '{"number":' .. tostring(98 + index) .. ',"title":"fkst-dev board","user":{"login":"fkst-test-bot"},"body":"'
      .. encode_body(body)
      .. '"}')
  end
  return "[[" .. table.concat(items, ",") .. "]]\n"
end

local function command_input_path(command)
  return tostring(command or ""):match("%-%-input '?([^'%s]+)'?")
end

local function dashboard_body_from_input(path)
  local raw = file.read(path)
  local body = raw:match('"body":"(.*)","labels"') or ""
  return body:gsub('\\"', '"'):gsub("\\n", "\n"):gsub("\\\\", "\\")
end

local function with_fake_dashboard_github(fake, callback)
  local old_label_get = core.gh_dashboard_label_get
  local old_issue_list = core.gh_dashboard_issue_list
  local old_issue_create = core.gh_dashboard_issue_create
  core.gh_dashboard_label_get = function(repo, label)
    table.insert(fake.commands, "label_get")
    if repo == "owner/repo" and label == core.dashboard_label() then
      return { stdout = '{"name":"fkst-dashboard"}\n', stderr = "", exit_code = 0 }
    end
    error("unexpected dashboard label get")
  end
  core.gh_dashboard_issue_list = function(repo, label)
    table.insert(fake.commands, "issue_list")
    if repo == "owner/repo" and label == core.dashboard_label() then
      fake.list_calls = fake.list_calls + 1
      return { stdout = dashboard_issue_list_stdout(fake.issue_body), stderr = "", exit_code = 0 }
    end
    error("unexpected dashboard issue list")
  end
  core.gh_dashboard_issue_create = function(repo, input_file)
    table.insert(fake.commands, "issue_create")
    if repo ~= "owner/repo" then
      error("unexpected dashboard issue create")
    end
    fake.create_calls = fake.create_calls + 1
    fake.issue_body = dashboard_body_from_input(input_file)
    return { stdout = '{"number":99}\n', stderr = "", exit_code = 0 }
  end
  local results = { pcall(callback) }
  core.gh_dashboard_label_get = old_label_get
  core.gh_dashboard_issue_list = old_issue_list
  core.gh_dashboard_issue_create = old_issue_create
  local ok = table.remove(results, 1)
  if not ok then
    error(results[1])
  end
  return unpack_results(results)
end

local function with_lock_capture(captured, callback)
  local old_with_lock = with_lock
  with_lock = function(key, fn)
    table.insert(captured, key)
    return fn()
  end
  local results = { pcall(callback) }
  with_lock = old_with_lock
  local ok = table.remove(results, 1)
  if not ok then
    error(results[1])
  end
  return unpack_results(results)
end

local function dashboard_fixture()
  return core.render_observability_dashboard({
    entities = {},
    counts = {},
    stalls = {},
    now_seconds = now(),
  })
end

local function trusted(body, created_at)
  return {
    body = body,
    author_login = "fkst-test-bot",
    created_at = created_at,
  }
end

local function untrusted(body, created_at)
  return {
    body = body,
    author_login = "mallory",
    created_at = created_at,
  }
end

local function entity(proposal_id, issue_number, state, version, comments, extra)
  local item = {
    proposal_id = proposal_id,
    issue_number = issue_number,
    state = {
      state = state,
      version = version,
      marker_created_at = comments[#comments].created_at,
    },
    parent_issue = { comments = comments },
  }
  for key, value in pairs(extra or {}) do
    item[key] = value
  end
  return item
end

return {
  test_observability_span_metrics_are_deterministic_from_trusted_markers = function()
    local now_seconds = core.iso_timestamp_epoch_seconds("2026-06-03T04:00:00Z")
    local proposal_1 = "github-devloop/issue/owner/repo/42"
    local proposal_2 = "github-devloop/issue/owner/repo/43"
    local proposal_3 = "github-devloop/issue/owner/repo/44"
    local ready_version = "ready-version"
    local implementing_version = "implementing-version"
    local thinking_version = "thinking-version"
    local source_ref = core.issue_source_ref("owner/repo", 44)
    local sr_digest = core.source_ref_digest(source_ref)
    local comments_1 = {
      trusted(core.state_marker(proposal_1, "ready", ready_version), "2026-06-03T00:00:00Z"),
      trusted(core.state_marker(proposal_1, "implementing", implementing_version), "2026-06-03T00:30:00Z"),
      trusted(core.implement_attempt_marker(proposal_1, implementing_version, 1, tostring(now_seconds - 15 * 60)), "2026-06-03T03:45:00Z"),
      trusted(core.state_marker(proposal_1, "pr-open", implementing_version), "2026-06-03T01:00:00Z"),
      untrusted(core.state_marker(proposal_1, "blocked", "forged"), "2026-06-03T03:59:00Z"),
    }
    local comments_2 = {
      trusted(core.state_marker(proposal_2, "ready", ready_version), "2026-06-03T01:00:00Z"),
      trusted(core.state_marker(proposal_2, "implementing", implementing_version), "2026-06-03T02:00:00Z"),
      trusted(core.implement_attempt_marker(proposal_2, implementing_version, 1, tostring(now_seconds - 30 * 60)), "2026-06-03T03:30:00Z"),
    }
    local comments_3 = {
      trusted(core.state_marker(proposal_3, "thinking", thinking_version), "2026-06-03T02:00:00Z"),
      trusted(core.converge_round_marker(proposal_3, thinking_version, sr_digest, 1, thinking_version .. "/loop/1", "Narrow", {}), "2026-06-03T03:50:00Z"),
    }
    local entities = {
      entity(proposal_1, 42, "pr-open", implementing_version, comments_1),
      entity(proposal_2, 43, "implementing", implementing_version, comments_2),
      entity(proposal_3, 44, "thinking", thinking_version, comments_3, { source_ref = source_ref }),
    }

    local first = core.observability_span_metrics(entities, now_seconds)
    local second = core.observability_span_metrics(entities, now_seconds)

    t.eq(first.by_state["implementing"].open_count, 1)
    t.eq(first.by_state["implementing"].avg_open_dwell_seconds, 1800)
    t.eq(first.by_state["implementing"].open_anchor, "heartbeat")
    t.eq(first.by_state["thinking"].open_count, 1)
    t.eq(first.by_state["thinking"].avg_open_dwell_seconds, 600)
    t.eq(first.by_state["thinking"].open_anchor, "heartbeat")
    t.eq(first.by_state["ready"].completed_count, 2)
    t.eq(first.by_state["ready"].avg_completed_seconds, 2700)
    t.eq(first.by_state["implementing"].completed_count, 1)
    t.eq(first.by_state["implementing"].avg_completed_seconds, 1800)
    local transition_counts = {}
    for _, transition in ipairs(first.transitions) do
      transition_counts[transition.transition] = transition.count
    end
    t.eq(transition_counts["implementing->pr-open"], 1)
    t.eq(transition_counts["ready->implementing"], 2)
    t.eq(first.recent_window_seconds, 21600)
    t.eq(first.by_state.blocked, nil)
    t.eq(first.summary_hash, second.summary_hash)

    local dashboard = core.render_observability_dashboard({
      entities = entities,
      counts = { ["pr-open"] = 1, implementing = 1, thinking = 1 },
      stalls = {},
      span_metrics = first,
      now_seconds = now_seconds,
    })
    t.is_true(dashboard.body:find("## State spans", 1, true) ~= nil)
    t.is_true(dashboard.body:find("- implementing: open=1 avg-open=30m completed=1 avg-completed=30m completed-samples=30m anchor=heartbeat", 1, true) ~= nil)
    t.is_true(dashboard.body:find("- thinking: open=1 avg-open=10m completed=0 avg-completed=unknown completed-samples=none anchor=heartbeat", 1, true) ~= nil)
    t.is_true(dashboard.body:find("- ready: open=0 avg-open=unknown completed=2 avg-completed=45m completed-samples=30m, 1h 0m anchor=state-entry", 1, true) ~= nil)
    t.is_true(dashboard.body:find("## Recent transitions", 1, true) ~= nil)
    t.is_true(dashboard.body:find("- ready->implementing: 2", 1, true) ~= nil)
    t.is_true(dashboard.body:find("- implementing->pr-open: 1", 1, true) ~= nil)
  end,

  test_dashboard_publish_defers_without_gh_calls_when_deadline_exhausted = function()
    mock_env("1")
    local gh_calls = 0
    local lock_calls = 0
    local old_gh_exec = core.gh_exec
    local old_with_lock = with_lock
    core.gh_exec = function()
      gh_calls = gh_calls + 1
      error("unexpected dashboard gh call")
    end
    with_lock = function(_, fn)
      lock_calls = lock_calls + 1
      return fn()
    end

    local ok, result = pcall(function()
      return core.publish_observability_dashboard("owner/repo", dashboard_fixture(), core.observability_limits(), now() - 1)
    end)
    core.gh_exec = old_gh_exec
    with_lock = old_with_lock

    t.eq(ok, true)
    t.eq(result, "deferred")
    t.eq(gh_calls, 0)
    t.eq(lock_calls, 0)
  end,

  test_dashboard_dry_run_logs_deferred_partial_board_when_deadline_exhausted = function()
    mock_env("")
    local captured = {}
    local old_log = log
    log = {
      info = function(message) table.insert(captured, tostring(message)) end,
      warn = function(message) table.insert(captured, tostring(message)) end,
      error = function(message) table.insert(captured, tostring(message)) end,
    }

    local result = core.publish_observability_dashboard("owner/repo", dashboard_fixture(), core.observability_limits(), now() - 1)
    log = old_log

    t.eq(result, "deferred")
    local body = table.concat(captured, "\n")
    t.is_true(body:find("tag=DASHBOARD_DEFERRED reason=deadline", 1, true) ~= nil)
    t.is_true(body:find("tag=DASHBOARD_DRY_RUN", 1, true) ~= nil)
    t.is_true(body:find("# fkst-dev board", 1, true) ~= nil)
  end,

  test_dashboard_publish_rereads_singleton_under_repo_lock = function()
    mock_env("1")
    local fake = { commands = {}, list_calls = 0, create_calls = 0, issue_body = nil }
    local lock_keys = {}

    local first, second = with_lock_capture(lock_keys, function()
      return with_fake_dashboard_github(fake, function()
        local dashboard = dashboard_fixture()
        return core.publish_observability_dashboard("owner/repo", dashboard, core.observability_limits(), now() + 90),
          core.publish_observability_dashboard("owner/repo", dashboard, core.observability_limits(), now() + 90)
      end)
    end)

    t.eq(first, "created")
    t.eq(second, "unchanged")
    t.eq(fake.create_calls, 1)
    t.eq(fake.list_calls, 2)
    t.eq(#lock_keys, 2)
    t.eq(lock_keys[1], "github-devloop/dashboard/owner/repo")
    t.eq(lock_keys[2], "github-devloop/dashboard/owner/repo")
  end,

  test_dashboard_locator_empty_stdout_fails_closed_without_create = function()
    mock_env("1")
    local old_label_get = core.gh_dashboard_label_get
    local old_issue_list = core.gh_dashboard_issue_list
    local old_issue_create = core.gh_dashboard_issue_create
    local create_calls = 0
    core.gh_dashboard_label_get = function(repo, label)
      if repo == "owner/repo" and label == core.dashboard_label() then
        return { stdout = '{"name":"fkst-dashboard"}\n', stderr = "", exit_code = 0 }
      end
      error("unexpected dashboard label get")
    end
    core.gh_dashboard_issue_list = function(repo, label)
      if repo == "owner/repo" and label == core.dashboard_label() then
        return { stdout = "", stderr = "", exit_code = 0 }
      end
      error("unexpected dashboard issue list")
    end
    core.gh_dashboard_issue_create = function()
      create_calls = create_calls + 1
      return { stdout = '{"number":99}\n', stderr = "", exit_code = 0 }
    end

    local ok, err = pcall(function()
      core.publish_observability_dashboard("owner/repo", dashboard_fixture(), core.observability_limits(), now() + 90)
    end)
    core.gh_dashboard_label_get = old_label_get
    core.gh_dashboard_issue_list = old_issue_list
    core.gh_dashboard_issue_create = old_issue_create

    t.eq(ok, false)
    t.is_true(tostring(err):find("dashboard issue list failed: empty output", 1, true) ~= nil)
    t.eq(create_calls, 0)
  end,

  test_dashboard_publish_adopts_duplicate_marker_issue_without_create = function()
    mock_env("1")
    local old_body = "old\n" .. core.dashboard_marker("old", "2026-06-01T00:00:00Z")
    local newer_body = "newer\n" .. core.dashboard_marker("newer", "2026-06-01T00:01:00Z")
    local old_label_get = core.gh_dashboard_label_get
    local old_issue_list = core.gh_dashboard_issue_list
    local old_issue_get = core.gh_dashboard_issue_get
    local old_issue_update = core.gh_dashboard_issue_update
    local old_issue_create = core.gh_dashboard_issue_create
    local create_calls = 0
    local get_calls = 0
    core.gh_dashboard_label_get = function(repo, label)
      if repo == "owner/repo" and label == core.dashboard_label() then
        return { stdout = '{"name":"fkst-dashboard"}\n', stderr = "", exit_code = 0 }
      end
      error("unexpected dashboard label get")
    end
    core.gh_dashboard_issue_list = function(repo, label)
      if repo == "owner/repo" and label == core.dashboard_label() then
        return { stdout = dashboard_issue_list_stdout_many({ old_body, newer_body }), stderr = "", exit_code = 0 }
      end
      error("unexpected dashboard issue list")
    end
    core.gh_dashboard_issue_get = function(repo, issue_number)
      if repo == "owner/repo" and tonumber(issue_number) == 99 then
        get_calls = get_calls + 1
        return { stdout = 'HTTP/2.0 200 OK\netag: "dashboard-old-etag"\n\n{"number":99,"title":"fkst-dev board","author":{"login":"fkst-test-bot"},"body":"' .. encode_body(old_body) .. '"}\n', stderr = "", exit_code = 0 }
      end
      error("unexpected dashboard issue get")
    end
    core.gh_dashboard_issue_update = function(repo, issue_number)
      if repo == "owner/repo" and tonumber(issue_number) == 99 then
        return { stdout = '{"number":99}\n', stderr = "", exit_code = 0 }
      end
      error("unexpected dashboard issue update")
    end
    core.gh_dashboard_issue_create = function()
      create_calls = create_calls + 1
      return { stdout = '{"number":101}\n', stderr = "", exit_code = 0 }
    end

    local result = core.publish_observability_dashboard("owner/repo", dashboard_fixture(), core.observability_limits(), now() + 90)
    core.gh_dashboard_label_get = old_label_get
    core.gh_dashboard_issue_list = old_issue_list
    core.gh_dashboard_issue_get = old_issue_get
    core.gh_dashboard_issue_update = old_issue_update
    core.gh_dashboard_issue_create = old_issue_create

    t.eq(result, "updated")
    t.eq(get_calls, 1)
    t.eq(create_calls, 0)
  end,
}
