local t = fkst.test

local fixture_prefix = "/tmp/fkst-liveness-failure-domain."

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function command_output(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok = handle:close()
  return output, ok ~= false and ok ~= nil
end

local function read_command(command)
  local output, ok = command_output(command)
  if not ok then
    error("liveness failure-domain fixture command failed: " .. tostring(command) .. "\n" .. tostring(output))
  end
  return output
end

local function run_command(command)
  read_command(command)
end

local function project_root()
  return read_command("pwd"):gsub("%s+$", "")
end

local function framework_bin()
  local bin = os.getenv("BIN") or ""
  if bin == "" then
    error("liveness failure-domain fixture requires BIN")
  end
  return bin
end

local function remove_fixture(root)
  if root:sub(1, #fixture_prefix) ~= fixture_prefix then
    error("refusing to remove unexpected fixture root: " .. tostring(root))
  end
  run_command("rm -rf " .. shell_quote(root))
end

local function write_fixture(root)
  local source_root = project_root()
  local package_root = root .. "/packages/github-devloop"
  run_command("mkdir -p " .. shell_quote(root .. "/packages"))
  run_command("cp -R " .. shell_quote(source_root .. "/libraries") .. " " .. shell_quote(root .. "/libraries"))
  run_command("find " .. shell_quote(root .. "/libraries") .. " -type d -name tests -prune -exec rm -rf {} +")
  for _, package_name in ipairs({ "github-devloop", "github-proxy", "github-devloop-decompose" }) do
    run_command("cp -R " .. shell_quote(source_root .. "/packages/" .. package_name)
      .. " " .. shell_quote(root .. "/packages/" .. package_name))
    run_command("rm -rf " .. shell_quote(root .. "/packages/" .. package_name .. "/tests"))
  end
  run_command("find " .. shell_quote(root .. "/packages")
    .. " -type d -path '*/departments/test_*' -prune -exec rm -rf {} +")

  run_command("rm -rf " .. shell_quote(package_root .. "/departments"))
  for _, department in ipairs({ "failure_domain_later", "failure_domain_start" }) do
    run_command("mkdir -p " .. shell_quote(package_root .. "/departments/" .. department))
  end
  for _, department in ipairs({ "dead_letter", "liveness_scan", "observe_issue" }) do
    run_command("cp -R " .. shell_quote(source_root .. "/packages/github-devloop/departments/" .. department)
      .. " " .. shell_quote(package_root .. "/departments/" .. department))
  end
  run_command("mkdir -p " .. shell_quote(package_root .. "/tests"))
  run_command("cp " .. shell_quote(source_root .. "/packages/github-devloop/tests/entity_read_mock_helpers.lua")
    .. " " .. shell_quote(package_root .. "/tests/entity_read_mock_helpers.lua"))

  file.write(root .. "/fkst.workspace.toml", [[
[workspace]
units = ["packages/*", "libraries/*"]
packages = ["packages/*"]
libraries = ["libraries/*"]
]])

  file.write(package_root .. "/departments/failure_domain_start/main.lua", [[
local M = {}

M.spec = {
  consumes = { "failure_domain_start" },
  produces = { "devloop_liveness_tick", "failure_domain_later" },
  stall_window = "1s",
}

function M.pipeline(_event)
  raise("devloop_liveness_tick", {
    schema = "github-devloop.tick.v1",
    dedup_key = "failure-domain/slot/1",
    source_ref = { kind = "cron", ref = "github-devloop/liveness-poll/slot/1" },
  })
  raise("failure_domain_later", {
    schema = "failure-domain.later.v1",
    dedup_key = "failure-domain/later",
    source_ref = { kind = "external", ref = "failure-domain/later" },
  })
end

return M
]])

  file.write(package_root .. "/departments/failure_domain_later/main.lua", [[
local M = {}

M.spec = {
  consumes = { "failure_domain_later" },
  produces = { "devloop_liveness_tick" },
  stall_window = "1s",
}

function M.pipeline(_event)
  raise("devloop_liveness_tick", {
    schema = "github-devloop.tick.v1",
    dedup_key = "failure-domain/slot/2",
    source_ref = { kind = "cron", ref = "github-devloop/liveness-poll/slot/2" },
  })
end

return M
]])

  file.write(package_root .. "/tests/failure_domain_graph_test.lua", [[
local base_ids = require("devloop.base_ids")
local core = require("core")
local devloop_base = require("devloop.base")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local graph = require("testkit.graph")

local t = fkst.test
local repo = "owner/repo"
local stuck_last = os.getenv("FKST_FIXTURE_STUCK_LAST") == "1"
local stuck_number = stuck_last and 2 or 1
local healthy_number = stuck_last and 1 or 2
local updated_at = "2026-06-03T01:02:03Z"

local function state_comment(number, state, version, created_at)
  return {
    body = core.state_marker(base_ids.proposal_id(repo, number), state, version),
    author_login = "fkst-test-bot",
    created_at = created_at,
  }
end

local function mock_env(name, value, times)
  for _ = 1, times or 32 do
    t.mock_command(devloop_base.read_env_command(name), {
      stdout = value or "",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function issue_fields(number, state, version, created_at, title)
  return {
    repo = repo,
    number = number,
    title = title,
    body = "",
    state = "OPEN",
    updated_at = updated_at,
    labels = { "fkst-dev:enabled", "fkst-dev:" .. state },
    comments = { state_comment(number, state, version, created_at) },
    assignees = { "fkst-test-bot" },
    author_login = "fkst-test-bot",
    register_all_views = true,
    times = 32,
  }
end

local function json_string(value)
  return '"' .. tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t") .. '"'
end

local function mock_production_issue_read(fields)
  local label_values = {}
  for _, label in ipairs(fields.labels or {}) do
    table.insert(label_values, '{"name":' .. json_string(label) .. "}")
  end
  local issue_stdout = table.concat({
    '{"number":', tostring(fields.number),
    ',"title":', json_string(fields.title),
    ',"body":"","state":"open","created_at":"2026-06-03T01:00:00Z"',
    ',"updated_at":', json_string(fields.updated_at),
    ',"labels":[', table.concat(label_values, ","), "]",
    ',"user":{"login":"fkst-test-bot"}',
    ',"assignees":[{"login":"fkst-test-bot"}]}\n',
  })
  local comment = fields.comments[1]
  local comments_stdout = table.concat({
    '[{"id":1,"body":', json_string(comment.body),
    ',"user":{"login":"fkst-test-bot"}',
    ',"created_at":', json_string(comment.created_at), "}]\n",
  })
  for _ = 1, 32 do
    t.mock_command("gh api repos/owner/repo/issues/" .. tostring(fields.number), {
      stdout = issue_stdout,
      stderr = "",
      exit_code = 0,
    })
    t.mock_command(
      "gh api --paginate --slurp repos/owner/repo/issues/"
        .. tostring(fields.number)
        .. "/comments?per_page=100",
      {
        stdout = comments_stdout,
        stderr = "",
        exit_code = 0,
      }
    )
  end
end

local function count_steps(trace, expected)
  local count = 0
  for _, step in ipairs(trace.steps or {}) do
    if (expected.queue == nil or step.queue == expected.queue)
      and (expected.consumer == nil or step.consumer == expected.consumer)
      and (expected.exit_code == nil or step.exit_code == expected.exit_code)
      and (expected.error == nil or tostring(step.error):find(expected.error, 1, true) ~= nil) then
      count = count + 1
    end
  end
  return count
end

local function raised_observations(trace, issue_number)
  local raised = {}
  for _, step in ipairs(trace.steps or {}) do
    for _, item in ipairs(step.raises or {}) do
      if item.queue == "github-devloop.devloop_observe_issue"
        and tonumber(item.payload and item.payload.number) == issue_number then
        table.insert(raised, item.payload)
      end
    end
  end
  return raised
end

local function timeout_attempt_receipts(trace, issue_number)
  local count = 0
  for _, step in ipairs(trace.steps or {}) do
    for _, item in ipairs(step.raises or {}) do
      local payload = item.payload or {}
      if item.queue == "github-proxy.github_issue_comment_request"
        and tonumber(payload.issue_number) == issue_number
        and tostring(payload.body):find("timeout-attempt", 1, true) ~= nil then
        count = count + 1
      end
    end
  end
  return count
end

return {
  test_stuck_entity_has_one_durable_failure_while_both_ticks_ack_and_healthy_progresses = function()
    mock_env("FKST_GITHUB_REPO", repo)
    mock_env("FKST_GITHUB_BOT_LOGIN", "fkst-test-bot")
    mock_env("FKST_GITHUB_AUTHORIZED_LOGINS", "")
    mock_env("FKST_DEVLOOP_MANAGED_BOT_LOGINS", "")
    mock_env("FKST_GITHUB_WRITE", "")

    local issues = {
      { number = 1, state = "open", updated_at = updated_at },
      { number = 2, state = "open", updated_at = updated_at },
    }
    entity_read_mocks.mock_issue_list_command(
      t,
      "gh api --paginate --slurp 'repos/owner/repo/issues?state=open&per_page=100'",
      issues,
      8
    )

    local stuck_version = "ready/consensus-" .. base_ids.proposal_id(repo, stuck_number)
      .. "/2026-06-03T01-02-03Z"
    local stuck_fields = issue_fields(
      stuck_number,
      "impl-failed",
      stuck_version,
      "2026-06-01T00:00:00Z",
      "Stuck issue"
    )
    entity_read_mocks.mock_issue_read_forms(t, stuck_fields)
    mock_production_issue_read(stuck_fields)

    local healthy_version = base_ids.proposal_id(repo, healthy_number) .. "/merged/2026-06-03T01-02-03Z"
    local healthy_fields = issue_fields(
      healthy_number,
      "merged",
      healthy_version,
      "2026-06-03T01:00:00Z",
      "Healthy issue"
    )
    entity_read_mocks.mock_issue_read_forms(t, healthy_fields)
    mock_production_issue_read(healthy_fields)

    local trace = graph.run({
      queue = "failure_domain_start",
      payload = {
        schema = "failure-domain.start.v1",
        dedup_key = "failure-domain/start",
        source_ref = { kind = "external", ref = "failure-domain/start" },
      },
      source_ref = { kind = "external", reference = "failure-domain/start" },
    }, { max_steps = 24 })

    t.eq(trace.status, "quiescent")
    t.eq(count_steps(trace, {
      queue = "github-devloop.devloop_liveness_tick",
      consumer = "github-devloop.liveness_scan",
      exit_code = 0,
    }), 2)
    t.eq(count_steps(trace, {
      queue = "github-devloop.devloop_observe_issue",
      consumer = "github-devloop.observe_issue",
      exit_code = 1,
      error = "github-devloop: liveness-scan-entity-failure:",
    }), 1)
    t.eq(count_steps(trace, {
      queue = "github-devloop.devloop_observe_issue",
      consumer = "github-devloop.observe_issue",
      exit_code = 1,
      error = "cause_error_class=timeout-redrive-stuck",
    }), 1)
    t.eq(count_steps(trace, {
      queue = "github-devloop.dead_letter",
      consumer = "github-devloop.dead_letter",
      exit_code = 0,
    }), 1)
    t.eq(trace.final.dead_letters, 1)

    local stuck_observations = raised_observations(trace, stuck_number)
    t.eq(#stuck_observations, 2)
    t.eq(stuck_observations[1].dedup_key, stuck_observations[2].dedup_key)
    t.is_true(stuck_observations[1].dedup_key:find(
      base_ids.proposal_id(repo, stuck_number),
      1,
      true
    ) ~= nil)
    t.eq(stuck_observations[1].source_ref.ref, repo .. "#issue/" .. tostring(stuck_number))
    t.eq(timeout_attempt_receipts(trace, stuck_number), 0)

    local healthy_reads = 0
    for _, call in ipairs(t.command_calls()) do
      if call.rendered == "gh api repos/owner/repo/issues/" .. tostring(healthy_number) then
        healthy_reads = healthy_reads + 1
      end
    end
    t.is_true(healthy_reads > 0)
  end,
}
]])

  return package_root
end

local function run_fixture(root, package_root, stuck_last)
  local command = table.concat({
    "FKST_RUNTIME_ROOT=" .. shell_quote(root .. "/runtime-" .. tostring(stuck_last)),
    "FKST_DURABLE_ROOT=" .. shell_quote(root .. "/durable-" .. tostring(stuck_last)),
    "FKST_RETRY_DEFAULT_MAX_ATTEMPTS=1",
    "FKST_RETRY_DEFAULT_BASE=1s",
    "FKST_RETRY_DEFAULT_CAP=1s",
    "FKST_FIXTURE_STUCK_LAST=" .. shell_quote(stuck_last and "1" or "0"),
    shell_quote(framework_bin()),
    "test",
    "--project-root", shell_quote(root),
    "--package-root", shell_quote(package_root),
    "--package-root", shell_quote(root .. "/packages/github-proxy"),
    "--package-root", shell_quote(root .. "/packages/github-devloop-decompose"),
  }, " ")
  read_command(command)
end

return {
  test_liveness_failure_domain_is_entity_local_in_both_orderings = function()
    local root = read_command("mktemp -d " .. shell_quote(fixture_prefix .. "XXXXXX")):gsub("%s+$", "")
    local ok, err = pcall(function()
      local package_root = write_fixture(root)
      run_fixture(root, package_root, false)
      run_fixture(root, package_root, true)
    end)
    local cleanup_ok, cleanup_err = pcall(remove_fixture, root)
    if not ok then
      error(err)
    end
    if not cleanup_ok then
      error(cleanup_err)
    end
  end,
}
