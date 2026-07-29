local conformance = require("testkit.namespaced_dispatch_conformance")
local t = fkst.test

local function load_department(path, module_name)
  local old_pipeline = pipeline
  local module = require(module_name)
  pipeline = old_pipeline
  return { path = path, module = module }
end

local departments = conformance.loaded_departments({
  load_department("departments/import_issue/main.lua", "departments.import_issue.main"),
  load_department("departments/radar_receipt_sink/main.lua", "departments.radar_receipt_sink.main"),
  load_department("departments/dead_letter/main.lua", "departments.dead_letter.main"),
})

local function source_ref(issue_number)
  local ref = "owner/repo#issue/" .. tostring(issue_number or 42)
  return {
    kind = "external",
    ref = ref,
    reference = ref,
  }
end

local function payload_for_queue(_path, queue)
  if queue == "github-proxy.github_issue_changed" or queue == "github-proxy.github_issue_observed" then
    return {
      schema = queue == "github-proxy.github_issue_observed" and "github-proxy.issue-observed.v1" or "github-proxy.v1",
      type = "issue",
      repo = "owner/repo",
      number = 42,
      title = "Marketing radar",
      state = "OPEN",
      labels = { "auto-twitter-marketing" },
      updated_at = "2026-07-28T09:00:00Z",
      source_ref = source_ref(42),
      dedup_key = "marketing-radar/namespaced/input",
      controls = {
        type = "radar-config",
        project = "chronoai",
      },
    }
  end
  if queue == "radar_config_imported" or queue == "marketing-radar.radar_config_imported" then
    return {
      schema = "marketing-radar.config-imported.v1",
      project = "chronoai",
      source_ref = source_ref(42),
      dedup_key = "marketing-radar/config/1",
    }
  end
  if queue == "radar_signal_imported" or queue == "marketing-radar.radar_signal_imported" then
    return {
      schema = "marketing-radar.signal-imported.v1",
      project = "chronoai",
      topic = "FKST hosted automation",
      source_ref = source_ref(42),
      dedup_key = "marketing-radar/signal/1",
    }
  end
  if queue == "radar_brief_created" or queue == "marketing-radar.radar_brief_created" then
    return {
      schema = "marketing-radar.brief-created.v1",
      project = "chronoai",
      week = "2026-W31",
      source_ref = source_ref(42),
      dedup_key = "marketing-radar/brief/1",
    }
  end
  if queue == "dead_letter" then
    return {
      queue = "marketing-radar.radar_probe",
      error = "namespaced dispatch fixture",
      source_ref = source_ref(42),
      dedup_key = "marketing-radar/dead-letter/1",
    }
  end
  error("marketing-radar: no fixture for queue " .. tostring(queue))
end

local function mock_common_env()
  for _ = 1, 4 do
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
end

local function opts_for_case(_path, queue)
  mock_common_env()
  return {
    run_opts = {
      env = {
        FKST_RUNTIME_ROOT = "/tmp/fkst-packages-test/marketing-radar/namespaced-"
          .. tostring(queue):gsub("[^%w._-]", "_"),
      },
    },
    before_replay = function()
      mock_common_env()
    end,
  }
end

return {
  test_all_departments_accept_production_namespaced_consumed_queues = function()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "marketing-radar",
      package_root = "packages/marketing-radar",
      departments = departments,
      payload_for_queue = payload_for_queue,
      opts_for_case = opts_for_case,
    })
  end,
}
