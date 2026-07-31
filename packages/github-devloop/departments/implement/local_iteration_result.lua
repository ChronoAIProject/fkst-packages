local M = {}

local valid_declarations = {
  ["PASS:NONE"] = { kind = "PASS", fault_class = "NONE" },
  ["FAIL:SEMANTIC"] = { kind = "SEMANTIC_FAIL", fault_class = "SEMANTIC" },
  ["FAIL:CONFIGURATION"] = { kind = "CONFIGURATION_FAIL", fault_class = "CONFIGURATION" },
  ["FAIL:TOOLCHAIN"] = { kind = "TOOLCHAIN_FAIL", fault_class = "TOOLCHAIN" },
  ["FAIL:INFRASTRUCTURE"] = { kind = "INFRASTRUCTURE_FAIL", fault_class = "INFRASTRUCTURE" },
  ["UNKNOWN:UNKNOWN"] = { kind = "UNKNOWN", fault_class = "UNKNOWN" },
}

local marker_family_prefix = "FKST_LOCAL_ITERATION_RESULT:"
local marker_prefix = marker_family_prefix .. "v2:"

local function declarations_from(text, declarations)
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
    local value = line:match("^" .. marker_prefix .. "([A-Z_]+:[A-Z_]+)$")
    if value ~= nil then
      local declaration = valid_declarations[value]
      if declaration == nil then
        declarations.invalid = true
      elseif declarations.kind ~= nil then
        if declarations.kind == declaration.kind and declarations.fault_class == declaration.fault_class then
          declarations.duplicate = true
        else
          declarations.conflicting = true
        end
      else
        declarations.kind = declaration.kind
        declarations.fault_class = declaration.fault_class
      end
    elseif line:sub(1, #marker_family_prefix) == marker_family_prefix then
      declarations.invalid = true
    end
  end
end

local function outcome(kind, fault_class, exit_code, reason)
  return {
    kind = kind,
    fault_class = fault_class,
    exit_code = exit_code,
    reason = reason,
  }
end

local function unknown(exit_code, reason)
  return outcome("UNKNOWN", "UNKNOWN", exit_code, reason)
end

function M.from_command(command_result)
  if type(command_result) ~= "table" then
    return unknown(nil, "missing-command-result")
  end

  local exit_code = tonumber(command_result.exit_code)
  if exit_code == nil then
    return unknown(nil, "missing-exit-code")
  end
  if command_result.timed_out == true or (command_result.timed_out == nil and exit_code == 124) then
    return unknown(exit_code, "timed-out")
  end

  local declarations = {}
  declarations_from(command_result.stdout, declarations)
  declarations_from(command_result.stderr, declarations)
  if declarations.invalid then
    return unknown(exit_code, "invalid-declaration")
  end
  if declarations.duplicate then
    return unknown(exit_code, "duplicate-declarations")
  end
  if declarations.conflicting then
    return unknown(exit_code, "conflicting-declarations")
  end

  if declarations.kind ~= nil then
    local declared_pass = declarations.kind == "PASS"
    if (declared_pass and exit_code ~= 0) or (not declared_pass and exit_code == 0) then
      return unknown(exit_code, "exit-contract-mismatch")
    end
    return outcome(declarations.kind, declarations.fault_class, exit_code, "producer-declared")
  end
  if exit_code == 0 then
    return unknown(exit_code, "missing-declaration")
  end
  return unknown(exit_code, "untyped-nonzero")
end

return M
