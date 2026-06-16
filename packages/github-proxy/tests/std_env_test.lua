local env = require("std.env")
local t = fkst.test

local allowed_env = {
  FKST_TEST_VALUE = true,
}

return {
  test_read_env_command_uses_allowed_printf_helper = function()
    t.eq(env.read_env_command(allowed_env, "FKST_TEST_VALUE", {
      error_prefix = "std-test",
    }), 'printf %s "$FKST_TEST_VALUE"')

    t.raises(function()
      env.read_env_command(allowed_env, "HOME", {
        error_prefix = "std-test",
      })
    end)
  end,

  test_read_env_reads_present_value_with_injected_exec = function()
    local read_env = env.reader(allowed_env, {
      error_prefix = "std-test",
    })

    local value = read_env("FKST_TEST_VALUE", function(cmd)
      t.eq(cmd, 'printf %s "$FKST_TEST_VALUE"')
      return { stdout = "configured", stderr = "", exit_code = 0 }
    end)

    t.eq(value, "configured")
  end,

  test_read_env_treats_absent_or_failed_value_as_nil = function()
    local read_env = env.reader(allowed_env, {
      error_prefix = "std-test",
    })

    t.is_nil(read_env("FKST_TEST_VALUE", function(_cmd)
      return { stdout = "", stderr = "", exit_code = 0 }
    end))
    t.is_nil(read_env("FKST_TEST_VALUE", function(_cmd)
      return { stdout = "configured", stderr = "", exit_code = 1 }
    end))
    t.is_nil(read_env("FKST_TEST_VALUE", function(_cmd)
      error("boom")
    end))
    t.is_nil(read_env("FKST_TEST_VALUE", nil))
  end,

  test_read_env_can_require_exec_sync = function()
    local read_env = env.reader(allowed_env, {
      error_prefix = "std-test",
      require_exec = true,
      missing_exec_error = "read_env requires exec_sync",
    })

    local old_exec_sync = exec_sync
    exec_sync = nil
    local ok = pcall(function()
      read_env("FKST_TEST_VALUE", nil)
    end)
    exec_sync = old_exec_sync
    t.eq(ok, false)
  end,
}
