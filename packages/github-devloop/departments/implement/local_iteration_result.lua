local M = {}
local strings = require("contract.strings")
local failure_identity = require("devloop.local_iteration_failure_identity")

local json = json

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
local identity_family_prefix = "FKST_LOCAL_ITERATION_FAILURE_IDENTITY:"
local identity_prefix = failure_identity.prefix

local function nonempty_string(value)
  return type(value) == "string" and value ~= ""
end

local function exact_keys(value, expected)
  for key in pairs(value) do
    if expected[key] ~= true then
      return false
    end
  end
  for key in pairs(expected) do
    if value[key] == nil then
      return false
    end
  end
  return true
end

local function identity_json_string(value)
  return strings.json_string(value):gsub("<", "\\u003c")
end

local function control_line(encoded)
  local line = identity_prefix .. encoded
  return failure_identity.validate_line(line) and line or nil
end

local function canonical_identity(encoded)
  local ok, value = pcall(json.decode, encoded)
  if not ok or type(value) ~= "table" or type(value.kind) ~= "string" then
    return nil
  end
  if value.kind == "check" then
    if not exact_keys(value, { kind = true, command = true })
      or not nonempty_string(value.command) then
      return nil
    end
    return control_line('{"command":' .. identity_json_string(value.command) .. ',"kind":"check"}')
  end
  if value.kind == "test" then
    local keys = {
      kind = true,
      owner_namespace = true,
      file = true,
      name = true,
      failure_kind = true,
    }
    if not exact_keys(value, keys)
      or not nonempty_string(value.owner_namespace)
      or not nonempty_string(value.file)
      or not nonempty_string(value.name)
      or (value.failure_kind ~= "assertion_failure" and value.failure_kind ~= "test_error") then
      return nil
    end
    return control_line('{"failure_kind":' .. identity_json_string(value.failure_kind)
      .. ',"file":' .. identity_json_string(value.file)
      .. ',"kind":"test"'
      .. ',"name":' .. identity_json_string(value.name)
      .. ',"owner_namespace":' .. identity_json_string(value.owner_namespace) .. '}')
  end
  return nil
end

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
    elseif line:sub(1, #identity_prefix) == identity_prefix then
      local identity = canonical_identity(line:sub(#identity_prefix + 1))
      if identity == nil then
        declarations.invalid_identity = true
      else
        declarations.failure_identities[identity] = true
      end
    elseif line:sub(1, #identity_family_prefix) == identity_family_prefix then
      declarations.invalid_identity = true
    end
  end
end

local function outcome(kind, fault_class, exit_code, reason, identities)
  return {
    kind = kind,
    fault_class = fault_class,
    exit_code = exit_code,
    reason = reason,
    failure_identities = identities or {},
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

  local declarations = { failure_identities = {} }
  declarations_from(command_result.stdout, declarations)
  declarations_from(command_result.stderr, declarations)
  if declarations.invalid then
    return unknown(exit_code, "invalid-declaration")
  end
  if declarations.invalid_identity then
    return unknown(exit_code, "invalid-failure-identity")
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
    local identities = {}
    for identity in pairs(declarations.failure_identities) do
      table.insert(identities, identity)
    end
    table.sort(identities)
    local identities_valid, identity_reason = failure_identity.validate_set(identities)
    if not identities_valid then
      if identity_reason == "set-too-large" then
        return unknown(exit_code, "failure-identity-set-too-large")
      end
      return unknown(exit_code, "invalid-failure-identity")
    end
    return outcome(declarations.kind, declarations.fault_class, exit_code, "producer-declared", identities)
  end
  if exit_code == 0 then
    return unknown(exit_code, "missing-declaration")
  end
  return unknown(exit_code, "untyped-nonzero")
end

return M
