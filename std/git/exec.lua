local M = {}

local function misuse_error(argv, context)
  local bad_program
  if type(argv) == "table" then
    bad_program = argv[1]
  end
  local message = "std.git: " .. tostring(context) .. " adapter misuse: expected git argv, got "
    .. tostring(bad_program)
  error(setmetatable({
    class = "git-adapter-misuse",
    expected_program = "git",
    bad_program = bad_program,
    message = message,
  }, {
    __tostring = function(err)
      return err.message
    end,
  }))
end

local function failure_error(result, context)
  return setmetatable({
    class = "git-command-failed",
    result = result,
    message = "std.git: " .. tostring(context) .. " failed",
  }, {
    __tostring = function(err)
      return err.message
    end,
  })
end

function M.run_result(exec, argv, timeout, context)
  if type(argv) ~= "table" or #argv < 1 or argv[1] ~= "git" then
    misuse_error(argv, context)
  end
  local result = exec({ argv = argv, timeout = timeout })
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    return false, failure_error(result, context)
  end
  return true, result
end

function M.run(exec, argv, timeout, context)
  local ok, result_or_error = M.run_result(exec, argv, timeout, context)
  if not ok then
    error(result_or_error)
  end
  return result_or_error
end

return M
