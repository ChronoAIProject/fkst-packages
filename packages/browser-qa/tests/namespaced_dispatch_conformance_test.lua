local conformance = require("testkit.namespaced_dispatch_conformance")
local t = fkst.test

local function load_department(path, module_name)
  local old_pipeline = pipeline
  local module = require(module_name)
  pipeline = old_pipeline
  return { path = path, module = module }
end

local departments = conformance.loaded_departments({
  load_department("departments/run/main.lua", "departments.run.main"),
})

local function payload_for_queue(_path, queue)
  if queue == "browser_qa_request" then
    return {
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
  end
  error("browser-qa: no production-shaped queue fixture for " .. tostring(queue))
end

local function opts_for_case()
  return {
    run_opts = {
      env = {
        BROWSER_QA_RUNNER = "playwright",
        BROWSER_QA_COMMAND = "printf browser-qa-ok",
        BROWSER_QA_TIMEOUT_SECONDS = "5",
        BROWSER_QA_WORKDIR = ".",
      },
    },
  }
end

return {
  test_all_departments_accept_production_namespaced_consumed_queues = function()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "browser-qa",
      package_root = "packages/browser-qa",
      departments = departments,
      payload_for_queue = payload_for_queue,
      opts_for_case = opts_for_case,
    })
  end,
}
