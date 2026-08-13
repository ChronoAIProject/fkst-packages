local h = require("tests.devloop_ops_helpers")
local t = h.t
local core = h.core
require("departments.observability.main")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local gh_argv = require("testkit_internal.gh_argv_mock")
local author_policy = require("testkit_internal.github_author_policy")
local decompose_lib = require("devloop.decompose")
local m_builders = require("devloop.markers.builders")
local parsers_misc = require("devloop.parsers.misc")
local function opts(name, extra)
  local env = {
    FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/github-devloop/" .. tostring(now()) .. "/" .. tostring(name),
    FKST_GITHUB_REPO = "owner/repo",
    FKST_GITHUB_BOT_LOGIN = "fkst-test-bot",
    FKST_GITHUB_WRITE = "",
    FKST_DEVLOOP_UPSTREAM_BRANCH = "dev",
    FKST_DEVLOOP_INTEGRATION_BRANCH = "integration/dev",
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return { env = env }
end
local function run_observability(run_opts)
  return t.run_department("departments/observability/main.lua", {
    queue = "devloop_observe_tick",
    payload = { schema = "github-devloop.observe-tick.v1" },
  }, run_opts or opts("observability"))
end
local function mock_env(bot_login, write_mode)
  author_policy.mock_env(t, {
    env = {
      FKST_GITHUB_BOT_LOGIN = bot_login == nil and "fkst-test-bot" or bot_login,
      FKST_DEVLOOP_MANAGED_BOT_LOGINS = "fkst-test-bot,ElonSG",
      FKST_GITHUB_AUTHORIZED_LOGINS = "trusted-human",
    },
  }, {
    configure_trusted_bot_login = parsers_misc.configure_trusted_bot_login,
    times = 16,
  })
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
    stdout = "owner/repo",
    stderr = "",
    exit_code = 0,
  })
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_GITHUB_WRITE"', {
      stdout = write_mode or "",
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
local function encode_json_string(value)
  return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end
local function observe_issue_list_command(label, page)
  return core.gh_issue_list_observe_cmd("owner/repo", label, page or 1)
end
local function observe_issue_list_first_command(label)
  return core.gh_issue_list_observe_cmd("owner/repo", label, 1, true)
end
local function observe_pr_list_command(page)
  return core.gh_pr_list_observe_cmd("owner/repo", page or 1)
end
local function observe_pr_list_first_command()
  return core.gh_pr_list_observe_cmd("owner/repo", 1, true)
end
local function render_comment(body, author, created_at)
  return string.format(
    '{"body":"%s","author":{"login":"%s"},"createdAt":"%s"}',
    encode_json_string(body),
    encode_json_string(author or "fkst-test-bot"),
    encode_json_string(created_at or "2026-06-03T01:02:03Z")
  )
end
local function wait_marker(proposal_id, version, unmet)
  local items = {}
  for _, number in ipairs(unmet or {}) do
    table.insert(items, tostring(number))
  end
  return '<!-- fkst:github-devloop:dependency-wait:v1 proposal="' .. tostring(proposal_id)
    .. '" version="' .. tostring(version)
    .. '" hold_kind="waiting" reason="waiting-on-dependency" unmet="' .. table.concat(items, ",")
    .. '" -->'
end
local function mock_all_issue_lists(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    local number = type(item) == "table" and item.number or item
    local state = type(item) == "table" and item.state or "open"
    table.insert(rendered, string.format('{"number":%d,"state":"%s"}', number, encode_json_string(state)))
  end
  local stdout = "[" .. table.concat(rendered, ",") .. "]\n"
  t.mock_command(observe_issue_list_first_command(core._enabled_label), {
    stdout = stdout,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(observe_issue_list_first_command(core._hold_label), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  if #rendered >= 100 then
    t.mock_command(observe_issue_list_command(core._enabled_label, 2), {
      stdout = "[]\n",
      stderr = "",
      exit_code = 0,
    })
  end
  for _, state in ipairs(core.lifecycle_state_order()) do
    t.mock_command(observe_issue_list_first_command(core.state_label(state)), { stdout = "[]\n", stderr = "", exit_code = 0 })
  end
end

local function mock_pr_list(items)
  local rendered = {}
  for _, item in ipairs(items or {}) do
    local number = type(item) == "table" and item.number or item
    local state = type(item) == "table" and item.state or "open"
    table.insert(rendered, string.format('{"number":%d,"state":"%s"}', number, encode_json_string(state)))
  end
  t.mock_command(observe_pr_list_first_command(), { stdout = "[" .. table.concat(rendered, ",") .. "]\n", stderr = "", exit_code = 0 })
  if #rendered >= 100 then
    t.mock_command(observe_pr_list_command(2), { stdout = "[]\n", stderr = "", exit_code = 0 })
  end
  t.mock_command(core.gh_pr_list_recent_merged_cmd("owner/repo", core.observability_limits().entity_cap), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(core.gh_issue_list_recent_closed_cmd("owner/repo", core.observability_limits().entity_cap), {
    stdout = "[]\n",
    stderr = "",
    exit_code = 0,
  })
end


local function mock_issue_view(comments, state, extra)
  extra = extra or {}
  entity_read_mocks.mock_issue_view_selector(t, {
    number = extra.number,
    title = extra.title or "Observed issue",
    state = state or extra.state or "OPEN",
    comments = comments,
    assignees = extra.assignees or {},
    author_login = extra.author or "fkst-test-bot",
  }, "title,body,comments,labels,state,stateReason,assignees,author")
end

local function mock_pr_view(comments, extra)
  extra = extra or {}
  entity_read_mocks.mock_pr_view_selector(t, {
    number = extra.number,
    head = extra.head_ref_name or "devloop-owner-repo-42",
    head_sha = extra.head_sha or "def456",
    base_branch = extra.base_branch or "integration/dev",
    state = extra.state or "OPEN",
    updated_at = extra.updated_at or "2026-06-03T02:03:04Z",
    comments = comments,
    labels = extra.labels or {},
  }, entity_read_mocks.pr_origin_selector)
end

local function count_calls(needle)
  return gh_argv.count_calls(t, needle)
end

local function has_call(needle)
  return count_calls(needle) > 0
end

local function first_call(needle)
  for _, call in ipairs(t.command_calls()) do
    if gh_argv.call_contains(call, needle) then return call end
  end
  return nil
end


local observability_pipeline = nil

local function run_observability_pipeline(event)
  local old_pipeline = pipeline
  local module = require("departments.observability.main")
  observability_pipeline = module.pipeline or pipeline or observability_pipeline
  pipeline = old_pipeline
  local run = observability_pipeline
  if type(run) ~= "function" then error("github-devloop: observability department pipeline missing") end
  event = event or { queue = "devloop_observe_tick", payload = { schema = "github-devloop.observe-tick.v1" } }
  run(event)
end

local function capture_observability_logs(event)
  local captured = {}
  local old_log = log
  log = {
    info = function(message)
      table.insert(captured, tostring(message))
    end,
    warn = function(message)
      table.insert(captured, tostring(message))
    end,
    error = function(message)
      table.insert(captured, tostring(message))
    end,
  }

  local ok, err = pcall(function()
    run_observability_pipeline(event)
  end)

  log = old_log
  if not ok then
    error(err)
  end
  return captured
end

local function try_capture_observability_logs(event)
  local captured = {}
  local old_log = log
  log = {
    info = function(message)
      table.insert(captured, tostring(message))
    end,
    warn = function(message)
      table.insert(captured, tostring(message))
    end,
    error = function(message)
      table.insert(captured, tostring(message))
    end,
  }

  local ok, err = pcall(function()
    run_observability_pipeline(event)
  end)

  log = old_log
  return ok, captured, err
end

local function summary_log(logs)
  for _, line in ipairs(logs or {}) do
    if line:find("tag=OBSERVE_SUMMARY", 1, true) ~= nil then
      return line
    end
  end
  return nil
end

local function stall_suspect_logs(logs)
  local matches = {}
  for _, line in ipairs(logs or {}) do
    if line:find("tag=STALL_SUSPECT", 1, true) ~= nil then
      table.insert(matches, line)
    end
  end
  return matches
end

local function version_minutes_ago(minutes)
  return os.date("!%Y-%m-%dT%H-%M-%SZ", now() - (tonumber(minutes) or 0) * 60)
end

local function dashboard_hash(body)
  return tostring(body or ""):match("<!%-%- fkst:dashboard:v1[^>]-hash=\"([^\"]+)\"[^>]*%-%->")
end

local function command_input_path(command)
  if type(command) == "table" then return gh_argv.argv_value_after(command, "--input") end
  return tostring(command or ""):match("%-%-input '([^']+)'") or tostring(command or ""):match("%-%-input%s+([^%s]+)")
end

local function command_body_file(command) return gh_argv.argv_value_after(command, "--body-file") end

local function dashboard_issue_list_command()
  return "gh api --paginate --slurp 'repos/owner/repo/issues?state=open&labels=fkst-dashboard&per_page=100'"
end

local function dashboard_label_get_command()
  return "gh api --method GET 'repos/owner/repo/labels/fkst-dashboard'"
end

local function dashboard_label_create_command()
  return "gh api --method POST 'repos/owner/repo/labels' -f 'name=fkst-dashboard' -f 'color=ededed' -f 'description=fkst observability dashboard singleton'"
end

local function devloop_branch(issue_number)
  return "devloop/issue/owner/repo/" .. tostring(issue_number) .. "/v1-1234567890"
end

local function mock_reaper_pr(proposal_id, issue_number, pr_number, comments)
  local branch = devloop_branch(issue_number)
  local all_comments = {
    render_comment(m_builders.pr_origin_marker(proposal_id, tostring(issue_number), branch, "v1", "integration/dev"), "fkst-test-bot"),
  }
  for _, comment in ipairs(comments or {}) do
    table.insert(all_comments, comment)
  end
  mock_pr_view(all_comments, { head_ref_name = branch })
  return branch
end

local function mock_pr_comment_write()
  t.mock_command("gh pr comment '7' --repo 'owner/repo' --body-file '/tmp/fkst-github-devloop-reap-", { stdout = "", stderr = "", exit_code = 0 })
end

local function mock_pr_close()
  t.mock_command("gh pr close '7' --repo 'owner/repo'", { stdout = "", stderr = "", exit_code = 0 })
end

local function mock_pr_close_failure()
  t.mock_command("gh pr close '7' --repo 'owner/repo'", { stdout = "", stderr = "close failed", exit_code = 1 })
end

local function mock_dashboard_label_exists()
  t.mock_command(dashboard_label_get_command(), {
    stdout = '{"name":"fkst-dashboard"}\n',
    stderr = "",
    exit_code = 0,
  })
end

local function mock_dashboard_issue_list(stdout, exit_code, stderr)
  mock_dashboard_label_exists()
  t.mock_command(dashboard_issue_list_command(), {
    stdout = stdout or "[[]]\n",
    stderr = stderr or "",
    exit_code = exit_code or 0,
  })
end

local function mock_dashboard_create()
  t.mock_command("gh api --method POST 'repos/owner/repo/issues' --input '/tmp/fkst-github-devloop-dashboard-owner-repo-", { stdout = '{"number":99}\n', stderr = "", exit_code = 0 })
end

local function mock_dashboard_patch(stdout, stderr, exit_code)
  t.mock_command("gh api --method PATCH 'repos/owner/repo/issues/99' --input '/tmp/fkst-github-devloop-dashboard-owner-repo-", { stdout = stdout or '{"number":99}\n', stderr = stderr or "", exit_code = exit_code or 0 })
end

local function assert_orphan_reaper_skips_parent_owned_by(ownership)
  local proposal_id = "github-devloop/issue/owner/repo/42"
  mock_env("fkst-test-bot", "1")
  mock_all_issue_lists({})
  mock_pr_list({ 7 })
  mock_reaper_pr(proposal_id, 42, 7)
  mock_issue_view({}, "CLOSED", ownership)
  mock_dashboard_issue_list()
  mock_dashboard_create()
  local logs = table.concat(capture_observability_logs(), "\n")
  t.eq(count_calls("gh pr comment"), 0)
  t.eq(count_calls("gh pr close"), 0)
  t.is_true(logs:find("reason=backing-issue-not-self-owned", 1, true) ~= nil)
end

return {
  h = h,
  t = t,
  core = core,
  entity_read_mocks = entity_read_mocks,
  gh_argv = gh_argv,
  decompose_lib = decompose_lib,
  m_builders = m_builders,
  opts = opts,
  run_observability = run_observability,
  mock_env = mock_env,
  encode_json_string = encode_json_string,
  observe_issue_list_command = observe_issue_list_command,
  observe_issue_list_first_command = observe_issue_list_first_command,
  observe_pr_list_command = observe_pr_list_command,
  observe_pr_list_first_command = observe_pr_list_first_command,
  render_comment = render_comment,
  wait_marker = wait_marker,
  mock_all_issue_lists = mock_all_issue_lists,
  mock_pr_list = mock_pr_list,
  mock_issue_view = mock_issue_view,
  mock_pr_view = mock_pr_view,
  count_calls = count_calls,
  has_call = has_call,
  first_call = first_call,
  observability_pipeline = observability_pipeline,
  run_observability_pipeline = run_observability_pipeline,
  capture_observability_logs = capture_observability_logs,
  try_capture_observability_logs = try_capture_observability_logs,
  summary_log = summary_log,
  stall_suspect_logs = stall_suspect_logs,
  version_minutes_ago = version_minutes_ago,
  dashboard_hash = dashboard_hash,
  command_input_path = command_input_path,
  command_body_file = command_body_file,
  dashboard_issue_list_command = dashboard_issue_list_command,
  dashboard_label_get_command = dashboard_label_get_command,
  dashboard_label_create_command = dashboard_label_create_command,
  devloop_branch = devloop_branch,
  mock_reaper_pr = mock_reaper_pr,
  mock_pr_comment_write = mock_pr_comment_write,
  mock_pr_close = mock_pr_close,
  mock_pr_close_failure = mock_pr_close_failure,
  mock_dashboard_label_exists = mock_dashboard_label_exists,
  mock_dashboard_issue_list = mock_dashboard_issue_list,
  mock_dashboard_create = mock_dashboard_create,
  mock_dashboard_patch = mock_dashboard_patch,
  assert_orphan_reaper_skips_parent_owned_by = assert_orphan_reaper_skips_parent_owned_by,
}
