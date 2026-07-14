-- Every consumed queue of every chrono-marketing department routes to a department
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
  load_department("departments/generate/main.lua", "departments.generate.main"),
})

local function entity_payload()
  return {
    schema = "github-proxy.v1",
    type = "issue",
    state = "OPEN",
    repo = "owner/repo",
    number = 42,
    title = "Announce the dashboard",
    body = "Draft a launch post for the new dashboard.",
    labels = { "fkst-company", "fkst-marketing" },
    updated_at = "2026-06-19T01:00:00Z",
    source_ref = { kind = "external", ref = "owner/repo#issue/42" },
    dedup_key = "owner/repo#issue#42@2026-06-19T01:00:00Z",
  }
end

local function payload_for_queue(_path, queue)
  if queue == "github-proxy.github_entity_changed" then
    return entity_payload()
  end
  error("chrono-marketing: no production-shaped queue fixture for " .. tostring(queue))
end

-- Keep the generate act hermetic if the harness executes it: a minimal drafted
-- content object from a mocked codex.
local function mock_hermetic_draft()
  t.mock_command("codex exec", {
    stdout = '{"title":"Introducing the dashboard","channel":"social",'
      .. '"body_markdown":"The new dashboard ships today.","image_prompt":"a clean dashboard"}',
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_all_departments_accept_production_namespaced_consumed_queues = function()
    mock_hermetic_draft()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "chrono-marketing",
      package_root = "packages/chrono-marketing",
      departments = departments,
      payload_for_queue = payload_for_queue,
    })
  end,
}
