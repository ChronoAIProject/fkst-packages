local result = require("std.result")
local t = fkst.test

return {
  test_require_success_returns_successful_result = function()
    local value = { exit_code = 0, stdout = "ok", stderr = "" }
    t.eq(result.require_success(value, "pkg: ", "demo"), value)
  end,

  test_require_success_raises_with_prefix_class_and_stderr = function()
    t.raises(function()
      result.require_success({ exit_code = 1, stderr = "bad" }, "pkg: ", "demo")
    end)
  end,
}
