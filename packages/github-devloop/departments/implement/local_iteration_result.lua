local M = {}

local valid_kinds = {
  PASS = true,
  SEMANTIC_FAIL = true,
  UNKNOWN = true,
}

local marker_prefix = "FKST_LOCAL_ITERATION_RESULT:v1:"

local function declarations_from(text, declarations)
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
    local value = line:match("^" .. marker_prefix .. "([A-Z_]+)$")
    if value ~= nil then
      if not valid_kinds[value] then
        declarations.invalid = true
      elseif declarations.kind ~= nil and declarations.kind ~= value then
        declarations.conflicting = true
      else
        declarations.kind = value
      end
    elseif line:sub(1, #marker_prefix) == marker_prefix then
      declarations.invalid = true
    end
  end
end

local function outcome(kind, exit_code, reason)
  return {
    kind = kind,
    exit_code = exit_code,
    reason = reason,
  }
end

function M.from_command(command_result)
  if type(command_result) ~= "table" then
    return outcome("UNKNOWN", nil, "missing-command-result")
  end

  local exit_code = tonumber(command_result.exit_code)
  if exit_code == nil then
    return outcome("UNKNOWN", nil, "missing-exit-code")
  end
  if command_result.timed_out == true or (command_result.timed_out == nil and exit_code == 124) then
    return outcome("UNKNOWN", exit_code, "timed-out")
  end

  local declarations = {}
  declarations_from(command_result.stdout, declarations)
  declarations_from(command_result.stderr, declarations)
  if declarations.invalid then
    return outcome("UNKNOWN", exit_code, "invalid-declaration")
  end
  if declarations.conflicting then
    return outcome("UNKNOWN", exit_code, "conflicting-declarations")
  end

  if declarations.kind == "UNKNOWN" then
    return outcome("UNKNOWN", exit_code, "producer-declared")
  end
  if declarations.kind == "PASS" then
    if exit_code ~= 0 then
      return outcome("UNKNOWN", exit_code, "exit-contract-mismatch")
    end
    return outcome("PASS", exit_code, "producer-declared")
  end
  if declarations.kind == "SEMANTIC_FAIL" then
    if exit_code == 0 then
      return outcome("UNKNOWN", exit_code, "exit-contract-mismatch")
    end
    return outcome("SEMANTIC_FAIL", exit_code, "producer-declared")
  end
  if exit_code == 0 then
    return outcome("PASS", exit_code, "exit-zero")
  end
  return outcome("UNKNOWN", exit_code, "untyped-nonzero")
end

return M
