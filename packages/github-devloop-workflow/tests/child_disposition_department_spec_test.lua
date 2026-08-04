local request_department = require("departments.workflow_child_disposition.main")
local handoff_department = require("departments.workflow_child_disposition_handoff.main")

local t = fkst.test

local function assert_bounded_retry(department)
  t.is_true(type(department.spec.retry) == "table")
  t.eq(department.spec.retry.max_attempts, 12)
  t.eq(department.spec.retry.base, "5s")
  t.eq(department.spec.retry.cap, "30s")
end

return {
  test_child_disposition_departments_declare_bounded_durable_retry = function()
    assert_bounded_retry(request_department)
    assert_bounded_retry(handoff_department)
  end,
}
