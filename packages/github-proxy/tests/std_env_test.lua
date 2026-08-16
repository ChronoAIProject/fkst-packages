local env = require("workflow_internal.env")
local github_env = require("core.env")
local t = fkst.test

local allowed_env = {
  FKST_OUTPUT_LANG = true,
  FKST_RUNTIME_ROOT = true,
  FKST_ENV_READ_ABSENT_SENTINEL = true,
  FKST_ENV_READ_MOCK_PRECEDENCE = true,
}

local function read_env_command(name)
  if not allowed_env[name] then
    error("env name is not allowed")
  end
  return 'printf %s "$' .. name .. '"'
end

local function with_global_read_doubles(values, fn)
  local original_env_read = env_read
  local original_exec_sync = exec_sync
  local counts = { env_reads = 0, spawns = 0 }
  _G.env_read = function(name)
    counts.env_reads = counts.env_reads + 1
    return values[name] or ""
  end
  _G.exec_sync = function(_command)
    counts.spawns = counts.spawns + 1
    return { stdout = "positive-control", stderr = "", exit_code = 0 }
  end
  local ok, err = pcall(fn, counts)
  _G.env_read = original_env_read
  _G.exec_sync = original_exec_sync
  if not ok then
    error(err, 0)
  end
end

local function with_env_read_absent(exec_double, fn)
  local original_env_read = env_read
  local original_exec_sync = exec_sync
  _G.env_read = nil
  _G.exec_sync = exec_double
  local ok, err = pcall(fn)
  _G.env_read = original_env_read
  _G.exec_sync = original_exec_sync
  if not ok then
    error(err, 0)
  end
end

return {
  test_read_env_returns_present_stdout = function()
    local value = env.read_env("FKST_OUTPUT_LANG", function(cmd)
      t.eq(cmd, 'printf %s "$FKST_OUTPUT_LANG"')
      return { stdout = "en", stderr = "", exit_code = 0 }
    end, read_env_command)

    t.eq(value, "en")
  end,

  test_read_env_returns_nil_for_absent_empty_and_failed_values = function()
    t.is_nil(env.read_env("FKST_OUTPUT_LANG", function(_cmd)
      return { stdout = "", stderr = "", exit_code = 0 }
    end, read_env_command))

    t.is_nil(env.read_env("FKST_OUTPUT_LANG", function(_cmd)
      return { stdout = "en", stderr = "", exit_code = 1 }
    end, read_env_command))

    t.is_nil(env.read_env("FKST_OUTPUT_LANG", nil, read_env_command))
  end,

  test_read_env_returns_nil_when_exec_fails = function()
    t.is_nil(env.read_env("FKST_OUTPUT_LANG", function(_cmd)
      error("exec failed")
    end, read_env_command))
  end,

  test_read_env_preserves_command_builder_allowlist_errors = function()
    t.raises(function()
      env.read_env("HOME", function(_cmd)
        return { stdout = "", stderr = "", exit_code = 0 }
      end, read_env_command)
    end)
  end,

  test_read_env_binds_command_builder = function()
    local read_env = env.read_env(read_env_command)

    t.eq(read_env("FKST_OUTPUT_LANG", function(cmd)
      t.eq(cmd, 'printf %s "$FKST_OUTPUT_LANG"')
      return { stdout = "zh", stderr = "", exit_code = 0 }
    end), "zh")
  end,

  test_bound_read_env_preserves_erroring_exec_contract = function()
    local read_env = env.read_env(read_env_command, {
      missing_exec_error = "read_env requires exec_sync",
      propagate_exec_errors = true,
    })

    t.raises(function()
      read_env("FKST_OUTPUT_LANG", nil)
    end)

    t.raises(function()
      read_env("HOME", function(_cmd)
        return { stdout = "", stderr = "", exit_code = 0 }
      end)
    end)

    t.is_nil(read_env("FKST_OUTPUT_LANG", function(_cmd)
      return { stdout = "en", stderr = "", exit_code = 1 }
    end))
  end,

  test_production_env_reads_do_not_use_exec_surface = function()
    with_global_read_doubles({
      FKST_RUNTIME_ROOT = "controlled-runtime-root",
    }, function(counts)
      local read_env = env.read_env(read_env_command)
      exec_sync("positive-control")
      t.eq(counts.spawns, 1)
      counts.spawns = 0

      t.eq(read_env("FKST_RUNTIME_ROOT"), "controlled-runtime-root")
      t.is_nil(read_env("FKST_ENV_READ_ABSENT_SENTINEL"))
      t.eq(counts.env_reads, 2)
      t.eq(counts.spawns, 0)
    end)
  end,

  test_production_env_reads_fall_back_to_exec_when_capability_is_absent = function()
    local calls = 0
    with_env_read_absent(function(command)
      calls = calls + 1
      t.eq(command, 'printf %s "$FKST_RUNTIME_ROOT"')
      return { stdout = "legacy-runtime-root", stderr = "", exit_code = 0 }
    end, function()
      local read_env = env.read_env(read_env_command)
      t.eq(read_env("FKST_RUNTIME_ROOT"), "legacy-runtime-root")
      t.eq(calls, 1)
    end)
  end,

  test_env_read_prefers_registered_mock_over_process_value = function()
    local read_env = env.read_env(read_env_command)
    t.mock_command(read_env_command("FKST_ENV_READ_MOCK_PRECEDENCE"), {
      stdout = "mock-runtime-root",
      stderr = "",
      exit_code = 0,
    })

    local value = read_env("FKST_ENV_READ_MOCK_PRECEDENCE")
    t.eq(value, "mock-runtime-root")
    local calls = t.command_calls()
    t.eq(#calls, 1)
    t.eq(calls[1].rendered, 'printf %s "$FKST_ENV_READ_MOCK_PRECEDENCE"')
    t.eq(calls[1].stdout, "mock-runtime-root")
  end,

  test_env_read_maps_nonzero_registered_mock_to_nil = function()
    local read_env = env.read_env(read_env_command)
    t.mock_command(read_env_command("FKST_OUTPUT_LANG"), {
      stdout = "must-not-leak",
      stderr = "failure",
      exit_code = 1,
    })

    t.is_nil(read_env("FKST_OUTPUT_LANG"))
  end,

  test_package_allowlist_error_matches_builder_without_lookup_or_spawn = function()
    with_global_read_doubles({}, function(counts)
      local builder_ok, builder_error = pcall(github_env.read_env_command, "HOME")
      local reader_ok, reader_error = pcall(github_env.read_env, "HOME")

      t.eq(builder_ok, false)
      t.eq(reader_ok, false)
      t.eq(reader_error, builder_error)
      t.eq(counts.env_reads, 0)
      t.eq(counts.spawns, 0)
    end)
  end,
}
