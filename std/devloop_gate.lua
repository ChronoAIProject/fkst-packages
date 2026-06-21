local M = {}

local allowed_lineage_fields = {
  proposal_id = true,
  issue_number = true,
  impl_version = true,
  branch = true,
  base_branch = true,
}

local facts_caps = setmetatable({}, { __mode = "k" })
local facts_methods = {}

function facts_methods.reached(self, milestone, opts)
  local caps = facts_caps[self]
  if caps == nil then
    error("std.devloop_gate: invalid facts capability")
  end
  return caps.reached(milestone, opts) == true
end

function facts_methods.lineage_equals(self, field, expected)
  local caps = facts_caps[self]
  if caps == nil then
    error("std.devloop_gate: invalid facts capability")
  end
  return caps.lineage_equals(field, expected) == true
end

local facts_meta = {
  __index = facts_methods,
  __newindex = function()
    error("std.devloop_gate: facts capability is read-only")
  end,
  __metatable = "std.devloop_gate.facts",
}

local function copy_lineage(lineage)
  if lineage == nil then
    return nil
  end
  if type(lineage) ~= "table" or getmetatable(lineage) ~= nil then
    error("std.devloop_gate: lineage must be a plain data table")
  end
  local copied = {}
  for field, required in pairs(lineage) do
    if allowed_lineage_fields[field] ~= true then
      error("std.devloop_gate: unsupported lineage field")
    end
    if required ~= true then
      error("std.devloop_gate: lineage requirements must be positive")
    end
    copied[field] = true
  end
  return copied
end

local function copy_opts(opts)
  if opts == nil then
    return {}
  end
  if type(opts) ~= "table" or getmetatable(opts) ~= nil then
    error("std.devloop_gate: options must be a plain data table")
  end
  local copied = {}
  for key, value in pairs(opts) do
    if key == "domain" or key == "milestone_domain" then
      copied[key] = tostring(value)
    elseif key == "lineage" then
      copied.lineage = copy_lineage(value)
    else
      error("std.devloop_gate: unsupported gate option")
    end
  end
  return copied
end

local function assert_no_smuggled_executable(value, seen)
  local value_type = type(value)
  if value_type == "function" or value_type == "thread" or value_type == "userdata" then
    error("std.devloop_gate: gate spec must be data-only")
  end
  if value_type ~= "table" then
    return
  end
  if getmetatable(value) ~= nil then
    error("std.devloop_gate: gate spec must not carry metatables")
  end
  seen = seen or {}
  if seen[value] then
    return
  end
  seen[value] = true
  for key, nested in pairs(value) do
    assert_no_smuggled_executable(key, seen)
    assert_no_smuggled_executable(nested, seen)
  end
end

local function assert_allowed_keys(value, allowed)
  for key in pairs(value) do
    if allowed[key] ~= true then
      error("std.devloop_gate: gate spec has non-AST fields")
    end
  end
end

local function assert_spec_shape(spec, seen)
  if type(spec) ~= "table" or getmetatable(spec) ~= nil then
    error("std.devloop_gate: gate spec must be a plain data table")
  end
  seen = seen or {}
  if seen[spec] then
    return
  end
  seen[spec] = true
  if spec.op == "all" then
    assert_allowed_keys(spec, { op = true, gates = true })
    if type(spec.gates) ~= "table" or getmetatable(spec.gates) ~= nil then
      error("std.devloop_gate: all gate requires a plain gate list")
    end
    for key, child in pairs(spec.gates) do
      if type(key) ~= "number" then
        error("std.devloop_gate: all gate list must be numeric")
      end
      assert_spec_shape(child, seen)
    end
    return
  end
  if spec.op == "reached" then
    assert_allowed_keys(spec, { op = true, milestone = true, opts = true })
    if type(spec.milestone) ~= "string" or spec.milestone == "" then
      error("std.devloop_gate: reached gate requires a milestone")
    end
    copy_opts(spec.opts)
    return
  end
  error("std.devloop_gate: unsupported gate operation")
end

local function reached_opts_for_facts(opts)
  local copied = {}
  if opts.domain ~= nil then
    copied.domain = opts.domain
  end
  if opts.milestone_domain ~= nil then
    copied.milestone_domain = opts.milestone_domain
  end
  return copied
end

local function binding_value(bindings, field)
  if type(bindings) ~= "table" or getmetatable(bindings) ~= nil then
    error("std.devloop_gate: bindings must be a plain data table")
  end
  local value = bindings[field]
  local value_type = type(value)
  if value_type == "nil" then
    return nil
  end
  if value_type == "table" or value_type == "function" or value_type == "thread" or value_type == "userdata" then
    error("std.devloop_gate: binding values must be scalar")
  end
  return value
end

local function lineage_holds(facts, opts, bindings)
  for field, required in pairs(opts.lineage or {}) do
    if required == true then
      local expected = binding_value(bindings, field)
      if expected == nil or not facts:lineage_equals(field, expected) then
        return false
      end
    end
  end
  return true
end

local function eval(spec, facts, bindings)
  if spec.op == "all" then
    for _, child in ipairs(spec.gates or {}) do
      if not eval(child, facts, bindings) then
        return false
      end
    end
    return true
  end
  if spec.op == "reached" then
    local opts = copy_opts(spec.opts)
    if not lineage_holds(facts, opts, bindings) then
      return false
    end
    return facts:reached(spec.milestone, reached_opts_for_facts(opts))
  end
  error("std.devloop_gate: unsupported gate operation")
end

function M.facts(caps)
  if type(caps) ~= "table" or type(caps.reached) ~= "function" or type(caps.lineage_equals) ~= "function" then
    error("std.devloop_gate: facts requires reached and lineage_equals capabilities")
  end
  local object = {}
  facts_caps[object] = {
    reached = caps.reached,
    lineage_equals = caps.lineage_equals,
  }
  return setmetatable(object, facts_meta)
end

function M.require_reached(milestone, opts)
  if type(milestone) ~= "string" or milestone == "" then
    error("std.devloop_gate: milestone is required")
  end
  return {
    op = "reached",
    milestone = milestone,
    opts = copy_opts(opts),
  }
end

function M.all(gates)
  if type(gates) ~= "table" or getmetatable(gates) ~= nil then
    error("std.devloop_gate: all requires a plain data list")
  end
  local copied = {}
  for index, child in ipairs(gates) do
    copied[index] = child
  end
  return {
    op = "all",
    gates = copied,
  }
end

function M.holds(spec, facts, bindings)
  if facts_caps[facts] == nil then
    error("std.devloop_gate: holds requires an opaque facts capability")
  end
  assert_no_smuggled_executable(spec)
  assert_spec_shape(spec)
  return eval(spec, facts, bindings or {})
end

return M
