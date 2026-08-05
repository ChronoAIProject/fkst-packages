local request_department = require("departments.workflow_child_disposition.main")

local t = fkst.test

local function assert_bounded_retry(department)
  t.is_true(type(department.spec.retry) == "table")
  t.eq(department.spec.retry.max_attempts, 12)
  t.eq(department.spec.retry.base, "5s")
  t.eq(department.spec.retry.cap, "30s")
end

return {
  test_child_disposition_department_declares_bounded_durable_retry = function()
    assert_bounded_retry(request_department)
  end,
}
