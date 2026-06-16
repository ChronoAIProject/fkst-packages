-- std.env: allowlisted environment readers via the engine shell primitive.
local S = {}

local allowed_options = {
  error_prefix = true,
}

local function validate_options(options)
  if options == nil then
    return
  end
  if type(options) ~= "table" then
    error("std.env: options must be a table")
  end
  for key, _ in pairs(options) do
    if not allowed_options[key] then
      error("std.env: unsupported option: " .. tostring(key))
    end
  end
end

local function env_error(options)
  local prefix = options and options.error_prefix
  if type(prefix) == "string" and prefix ~= "" then
    return prefix .. ": env name is not allowed"
  end
  return "env name is not allowed"
end

function S.read_env_command(allowed_env, name, options)
  validate_options(options)
  if type(allowed_env) ~= "table" or not allowed_env[name] then
    error(env_error(options))
  end
  return 'printf %s "$' .. name .. '"'
end

function S.read_env(allowed_env, name, exec, options)
  validate_options(options)
  local run = exec or exec_sync
  if type(run) ~= "function" then
    return nil
  end
  local command = S.read_env_command(allowed_env, name, options)
  local ok, out = pcall(run, command)
  if not ok or type(out) ~= "table" or out.exit_code ~= 0 or out.stdout == "" then
    return nil
  end
  return out.stdout
end

function S.reader(allowed_env, options)
  validate_options(options)
  return function(name, exec)
    return S.read_env(allowed_env, name, exec, options)
  end
end

function S.command_reader(allowed_env, options)
  validate_options(options)
  return function(name)
    return S.read_env_command(allowed_env, name, options)
  end
end

return S
