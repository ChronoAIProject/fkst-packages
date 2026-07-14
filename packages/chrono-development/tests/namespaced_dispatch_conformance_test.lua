local conformance = require("testkit.namespaced_dispatch_conformance")
local t = fkst.test

-- chrono-development is a composed PROFILE with a single owned department:
-- dead_letter (consumes the bare "dead_letter" queue). The conformance harness
-- discovers the department, loads its standard dead_letter handler, and routes a
-- production-shaped dead-letter payload. No other consumed queue exists, so the
-- payload_for_queue fixture below should never be reached.
local function payload_for_queue(_path, queue)
  error("chrono-development: no production-shaped queue fixture for " .. tostring(queue))
end

return {
  test_dead_letter_consumed_queue_routes = function()
    conformance.assert_all_consumed_queues_route({
      t = t,
      package_name = "chrono-development",
      package_root = "packages/chrono-development",
      departments = {},
      payload_for_queue = payload_for_queue,
    })
  end,
}
