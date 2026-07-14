-- Every consumed queue of every chrono-security department routes to a department
-- under a production-shaped fixture (no consumed queue falls through the
-- unknown/unsupported path). Modeled on
-- github-autochrono/tests/namespaced_dispatch_conformance_test.lua.
local conformance = require("testkit.namespaced_dispatch_conformance")
local t = fkst.test

local function load_department(path, module_name)
  -- Loading a department installs its pipeline into _G.pipeline; save/restore so
  -- requiring one department does not leak into the next.
  local old_pipeline = pipeline
  local module = require(module_name)
  pipeline = old_pipeline
  return { path = path, module = module }
end

local departments = conformance.loaded_departments({
  load_department("departments/scan/main.lua", "departments.scan.main"),
})

local function security_tick_payload()
  return {
    raiser = "chrono-security.security_poll",
    slot = "2026-06-19T01:00:00Z",
    detected_at = "2026-06-19T01:00:00Z",
  }
end

local function payload_for_queue(_path, queue)
  if queue == "security_tick" then
    return security_tick_payload()
  end
  error("chrono-security: no production-shaped queue fixture for " .. tostring(queue))
end

-- If the harness executes the scan act, keep it hermetic: a bounded env repo and a
-- zero-finding codex scan (no issue-create requests, still an accepted routing).
local function mock_hermetic_scan()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", { stdout = "[]", stderr = "", exit_code = 0 })
end

return {
  test_all_departments_accept_production_namespaced_consumed_queues = function()
    mock_hermetic_scan()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "chrono-security",
      package_root = "packages/chrono-security",
      departments = departments,
      payload_for_queue = payload_for_queue,
    })
  end,
}
