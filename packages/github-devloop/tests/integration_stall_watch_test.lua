local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

local function opts(name, extra)
  local env = {
    FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop/" .. tostring(now()) .. "/" .. tostring(name),
    FKST_GITHUB_REPO = "owner/repo",
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_GITHUB_WRITE = "",
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return { env = env }
end

local function run_stall_watch(name)
  return t.run_department("departments/stall_watch/main.lua", {
    queue = "devloop_observe_tick",
    payload = { schema = "github-devloop.observe-tick.v1" },
  }, opts(name or "stall-watch"))
end

local function run_stall_watch_issue(name)
  return t.run_department("departments/stall_watch/main.lua", {
    queue = "github-proxy.github_entity_changed",
    payload = {
      schema = "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = 42,
      title = "Issue",
      updated_at = "2026-06-10T08:00:00Z",
      source_ref = {
        kind = "external",
        ref = "owner/repo#issue/42",
      },
    },
  }, opts(name or "stall-watch-issue"))
end

local function mock_env()
  t.mock_command('printf %s "$FKST_GITHUB_BOT_LOGIN"', {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

local function json_string(value)
  return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

local function render_comment(body, author, created_at)
  return string.format(
    '{"body":"%s","author":{"login":"%s"},"createdAt":"%s"}',
    json_string(body),
    json_string(author or "fkst-test-bot"),
    json_string(created_at or "2026-06-10T08:00:00Z")
  )
end

local function render_label(name)
  return string.format('{"name":"%s"}', json_string(name))
end

local function mock_issue_list(label, numbers)
  local rendered = {}
  for _, number in ipairs(numbers or {}) do
    table.insert(rendered, string.format('{"number":%d,"state":"open"}', number))
  end
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/issues?state=open&labels=" .. label:gsub(":", "%%3A") .. "&per_page=100'", {
    stdout = "[[" .. table.concat(rendered, ",") .. "]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_open_issue_list(numbers)
  local rendered = {}
  for _, number in ipairs(numbers or {}) do
    table.insert(rendered, string.format('{"number":%d,"state":"open"}', number))
  end
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/issues?state=open&per_page=100'", {
    stdout = "[[" .. table.concat(rendered, ",") .. "]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_all_lists(_match_label, numbers)
  mock_open_issue_list(numbers)
  t.mock_command("gh api --paginate --slurp 'repos/owner/repo/pulls?state=open&per_page=100'", {
    stdout = "[[]]\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_view(labels, comments)
  local rendered_labels = {}
  for _, label in ipairs(labels or {}) do
    table.insert(rendered_labels, render_label(label))
  end
  local rendered_comments = {}
  for _, comment in ipairs(comments or {}) do
    if type(comment) == "table" then
      table.insert(rendered_comments, render_comment(comment.body, comment.author_login, comment.created_at))
    else
      table.insert(rendered_comments, render_comment(comment))
    end
  end
  t.mock_command("--json labels,state,comments", {
    stdout = '{"state":"OPEN","labels":[' .. table.concat(rendered_labels, ",") .. '],"comments":[' .. table.concat(rendered_comments, ",") .. "]}\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_observe_issue_view(comments)
  local rendered_comments = {}
  for _, comment in ipairs(comments or {}) do
    if type(comment) == "table" then
      table.insert(rendered_comments, render_comment(comment.body, comment.author_login, comment.created_at))
    else
      table.insert(rendered_comments, render_comment(comment))
    end
  end
  t.mock_command("--json comments,state", {
    stdout = '{"state":"OPEN","comments":[' .. table.concat(rendered_comments, ",") .. "]}\n",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_issue_views(labels, comments)
  mock_observe_issue_view(comments)
  mock_issue_view(labels, comments)
end

local function state_comment(proposal_id, state, version, created_at)
  return {
    body = core.state_marker(proposal_id, state, version),
    created_at = created_at,
  }
end

local function mock_pr_view(comments)
  local rendered_comments = {}
  for _, comment in ipairs(comments or {}) do
    if type(comment) == "table" then
      table.insert(rendered_comments, render_comment(comment.body, comment.author_login, comment.created_at))
    else
      table.insert(rendered_comments, render_comment(comment))
    end
  end
  t.mock_command("--json headRefName,headRefOid,baseRefName,state,updatedAt,comments", {
    stdout = '{"headRefName":"devloop-owner-repo-42","headRefOid":"def456","baseRefName":"dev","state":"OPEN","updatedAt":"2026-06-10T08:30:00Z","comments":[' .. table.concat(rendered_comments, ",") .. "]}\n",
    stderr = "",
    exit_code = 0,
  })
end

local function count_raises(result, queue)
  local count = 0
  for _, raise in ipairs(result.raises or {}) do
    if raise.queue == queue then
      count = count + 1
    end
  end
  return count
end

local function find_raise(result, queue)
  for _, raise in ipairs(result.raises or {}) do
    if raise.queue == queue then
      return raise
    end
  end
  return nil
end

local function capture_logs(fn)
  local captured = {}
  local old_log = log
  log = {
    info = function(message) table.insert(captured, tostring(message)) end,
    warn = function(message) table.insert(captured, tostring(message)) end,
    error = function(message) table.insert(captured, tostring(message)) end,
  }
  local ok, result = pcall(fn)
  log = old_log
  if not ok then
    error(result)
  end
  return captured, result
end

local function capture_stall_watch_logs(name)
  local event = {
    queue = "devloop_observe_tick",
    payload = { schema = "github-devloop.observe-tick.v1" },
  }
  return capture_logs(function()
    local source = package.searchpath("tests.integration_stall_watch_test", package.path)
    local package_root = source:match("(.+)/tests/integration_stall_watch_test%.lua$")
    dofile(package_root .. "/departments/stall_watch/main.lua")
    pipeline(event)
    return { exit_code = 0, raises = {} }
  end)
end

local function has_log(logs, needle)
  for _, line in ipairs(logs or {}) do
    if line:find(needle, 1, true) ~= nil then
      return true
    end
  end
  return false
end

return {
  test_breach_writes_one_marker_and_stalled_label = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "2026-06-10T06-00-00Z"
    mock_env()
    mock_all_lists(core._enabled_label, { 42 })
    mock_issue_views({ "fkst-dev:thinking" }, {
      state_comment(proposal_id, "thinking", version, "2026-06-10T06:00:00Z"),
    })

    local result = run_stall_watch("stall-breach")

    t.eq(result.exit_code, 0)
    t.eq(count_raises(result, "github-proxy.github_issue_comment_request"), 1)
    t.eq(count_raises(result, "github-proxy.github_issue_label_request"), 1)
    local comment = find_raise(result, "github-proxy.github_issue_comment_request").payload
    t.is_true(comment.body:find("fkst:github-devloop:stall-detected:v1", 1, true) ~= nil)
    t.is_true(comment.body:find('state="thinking"', 1, true) ~= nil)
    t.is_true(comment.body:find('version="' .. version .. '"', 1, true) ~= nil)
    t.eq(comment.source_ref.kind, "external")
    t.eq(comment.source_ref.ref, "owner/repo#issue/42")
    local label = find_raise(result, "github-proxy.github_issue_label_request").payload
    t.eq(label.add_labels[1], core._stalled_label)
    t.eq(label.source_ref.kind, "external")
    t.eq(label.source_ref.ref, "owner/repo#issue/42")
  end,

  test_entity_change_path_uses_stable_issue_source_ref = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "2026-06-10T06-00-00Z"
    mock_env()
    mock_issue_view({ "fkst-dev:thinking" }, {
      state_comment(proposal_id, "thinking", version, "2026-06-10T06:00:00Z"),
    })

    local result = run_stall_watch_issue("stall-entity-source-ref")

    t.eq(result.exit_code, 0)
    local comment = find_raise(result, "github-proxy.github_issue_comment_request").payload
    t.eq(comment.source_ref.kind, "external")
    t.eq(comment.source_ref.ref, "owner/repo#issue/42")
    local label = find_raise(result, "github-proxy.github_issue_label_request").payload
    t.eq(label.source_ref.kind, "external")
    t.eq(label.source_ref.ref, "owner/repo#issue/42")
  end,

  test_repeated_pass_is_idempotent_for_same_state_version = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "2026-06-10T06-00-00Z"
    mock_env()
    mock_all_lists(core._enabled_label, { 42 })
    mock_issue_views({ "fkst-dev:thinking", core._stalled_label }, {
      state_comment(proposal_id, "thinking", version, "2026-06-10T06:00:00Z"),
      core.stall_detected_marker(proposal_id, "thinking", version, core.stall_watch_threshold_seconds("thinking")),
    })

    local result = run_stall_watch("stall-idempotent")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_advanced_state_clears_stalled_label = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local old_version = "2026-06-10T06-00-00Z"
    local new_version = "2999-01-01T00-00-00Z"
    mock_env()
    mock_all_lists(core._enabled_label, { 42 })
    mock_issue_views({ "fkst-dev:reviewing", core._stalled_label }, {
      state_comment(proposal_id, "thinking", old_version, "2026-06-10T06:00:00Z"),
      core.stall_detected_marker(proposal_id, "thinking", old_version, core.stall_watch_threshold_seconds("thinking")),
      state_comment(proposal_id, "reviewing", new_version, "2999-01-01T00:00:00Z"),
    })

    local result = run_stall_watch("stall-clear")

    t.eq(result.exit_code, 0)
    t.eq(count_raises(result, "github-proxy.github_issue_comment_request"), 0)
    t.eq(count_raises(result, "github-proxy.github_issue_label_request"), 1)
    local label = find_raise(result, "github-proxy.github_issue_label_request").payload
    t.eq(label.remove_labels[1], core._stalled_label)
  end,

  test_advanced_overdue_state_writes_new_marker_without_clearing_stalled_label = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local old_version = "2026-06-10T06-00-00Z"
    local new_version = "2026-06-10T07-00-00Z"
    mock_env()
    mock_all_lists(core._enabled_label, { 42 })
    mock_issue_views({ "fkst-dev:reviewing", core._stalled_label }, {
      state_comment(proposal_id, "thinking", old_version, "2026-06-10T06:00:00Z"),
      core.stall_detected_marker(proposal_id, "thinking", old_version, core.stall_watch_threshold_seconds("thinking")),
      state_comment(proposal_id, "reviewing", new_version, "2026-06-10T07:00:00Z"),
    })

    local result = run_stall_watch("stall-advanced-overdue")

    t.eq(result.exit_code, 0)
    t.eq(count_raises(result, "github-proxy.github_issue_comment_request"), 1)
    t.eq(count_raises(result, "github-proxy.github_issue_label_request"), 0)
    local comment = find_raise(result, "github-proxy.github_issue_comment_request").payload
    t.is_true(comment.body:find('state="reviewing"', 1, true) ~= nil)
    t.is_true(comment.body:find('version="' .. new_version .. '"', 1, true) ~= nil)
  end,

  test_dependency_held_ready_entity_does_not_alert = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local version = "2026-06-10T06-00-00Z"
    mock_env()
    mock_all_lists(core._enabled_label, { 42 })
    mock_issue_views({ "fkst-dev:ready", core._blocked_on_dependency_label }, {
      state_comment(proposal_id, "ready", version, "2026-06-10T06:00:00Z"),
      core.dependency_wait_marker(proposal_id, version, { 1 }),
    })

    local result = run_stall_watch("stall-dependency-held")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_pr_local_reviewing_marker_prevents_stale_pr_open_alert = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local pr_open_version = "2026-06-10T06-00-00Z"
    local reviewing_version = "2999-01-01T00-00-00Z"
    mock_env()
    mock_all_lists(core._enabled_label, { 42 })
    mock_issue_views({ "fkst-dev:pr-open" }, {
      state_comment(proposal_id, "pr-open", pr_open_version, "2026-06-10T06:00:00Z"),
      core.pr_link_marker(proposal_id, 7, "devloop-owner-repo-42", pr_open_version, "dev"),
    })
    mock_pr_view({
      core.pr_origin_marker(proposal_id, "42", "devloop-owner-repo-42", pr_open_version, "dev"),
      state_comment(proposal_id, "reviewing", reviewing_version, "2999-01-01T00:00:00Z"),
    })
    mock_pr_view({
      core.pr_origin_marker(proposal_id, "42", "devloop-owner-repo-42", pr_open_version, "dev"),
      state_comment(proposal_id, "reviewing", reviewing_version, "2999-01-01T00:00:00Z"),
    })

    local result = run_stall_watch("stall-pr-local-reviewing")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_reused_old_version_does_not_alert_for_fresh_state_marker = function()
    local proposal_id = "github-devloop/issue/owner/repo/42"
    local reused_version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-10T06-00-00Z"
    mock_env()
    mock_all_lists(core._enabled_label, { 42 })
    mock_issue_views({ "fkst-dev:pr-open" }, {
      state_comment(proposal_id, "pr-open", reused_version, "2999-01-01T00:00:00Z"),
    })

    local result = run_stall_watch("stall-reused-version-fresh-transition")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,

  test_gh_failure_skips_without_alert_and_logs = function()
    mock_env()
    mock_all_lists(core._enabled_label, { 42 })
    mock_observe_issue_view({
      state_comment("github-devloop/issue/owner/repo/42", "thinking", "2026-06-10T06-00-00Z", "2026-06-10T06:00:00Z"),
    })
    t.mock_command("--json labels,state,comments", {
      stdout = "",
      stderr = "forced view failure",
      exit_code = 1,
    })

    local logs, result = capture_stall_watch_logs("stall-gh-failure")

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
    t.eq(has_log(logs, "tag=STALL_WATCH_SKIP"), true)
    t.eq(has_log(logs, "reason=issue-view-failed"), true)
  end,
}
