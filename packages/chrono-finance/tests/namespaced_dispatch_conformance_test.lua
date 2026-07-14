-- Every consumed queue of every chrono-finance department routes to a department
-- under a production-shaped fixture. Modeled on
-- github-autochrono/tests/namespaced_dispatch_conformance_test.lua.
local conformance = require("testkit.namespaced_dispatch_conformance")
local t = fkst.test

local function load_department(path, module_name)
  local old_pipeline = pipeline
  local module = require(module_name)
  pipeline = old_pipeline
  return { path = path, module = module }
end

local departments = conformance.loaded_departments({
  load_department("departments/report/main.lua", "departments.report.main"),
})

local function finance_tick_payload()
  return {
    raiser = "chrono-finance.finance_poll",
    slot = "2026-06-19T01:00:00Z",
    detected_at = "2026-06-19T01:00:00Z",
  }
end

local function payload_for_queue(_path, queue)
  if queue == "finance_tick" then
    return finance_tick_payload()
  end
  error("chrono-finance: no production-shaped queue fixture for " .. tostring(queue))
end

-- Keep the report act hermetic if the harness executes it: a bounded env repo and
-- a minimal zero-cost usage object.
local function mock_hermetic_report()
  t.mock_command('printf %s "$FKST_GITHUB_REPO"', { stdout = "owner/repo", stderr = "", exit_code = 0 })
  t.mock_command('printf %s "$FKST_FINANCE_BUDGET_MAX_UNITS"', { stdout = "", stderr = "", exit_code = 0 })
  t.mock_command("codex exec", {
    stdout = '{"summary":"no activity","total_units":0,"line_items":[]}',
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_all_departments_accept_production_namespaced_consumed_queues = function()
    mock_hermetic_report()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "chrono-finance",
      package_root = "packages/chrono-finance",
      departments = departments,
      payload_for_queue = payload_for_queue,
    })
  end,
}
