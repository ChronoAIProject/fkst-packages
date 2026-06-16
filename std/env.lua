-- std.env: allowlisted environment readers via the engine shell primitive.
local S = {}

local function env_error(options, name)
  local prefix = options and options.error_prefix
  if type(prefix) == "string" and prefix ~= "" then
    return prefix .. ": env name is not allowed"
  end
  if options and options.include_name then
    return "env name is not allowed: " .. tostring(name)
  end
  return "env name is not allowed"
end

function S.read_env_command(allowed_env, name, options)
  if type(allowed_env) ~= "table" or not allowed_env[name] then
    error(env_error(options, name))
  end
  return 'printf %s "$' .. name .. '"'
end

function S.read_env(allowed_env, name, exec, options)
  local run = exec or exec_sync
  if type(run) ~= "function" then
    if options and options.require_exec then
      error(options.missing_exec_error or "read_env requires exec_sync")
    end
    return nil
  end
  local command = S.read_env_command(allowed_env, name, options)
  if options and options.propagate_exec_errors then
    local out = run(command)
    if out.exit_code ~= 0 then
      return nil
    end
    if out.stdout == "" then
      return nil
    end
    return out.stdout
  end
  local ok, out = pcall(run, command)
  if not ok or type(out) ~= "table" or out.exit_code ~= 0 or out.stdout == "" then
    return nil
  end
  return out.stdout
end

function S.reader(allowed_env, options)
  return function(name, exec)
    return S.read_env(allowed_env, name, exec, options)
  end
end

function S.command_reader(allowed_env, options)
  return function(name)
    return S.read_env_command(allowed_env, name, options)
  end
end

return S
