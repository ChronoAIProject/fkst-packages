local adapter = require("browser_adapter")

local M = {}

local function production_runner(spec)
  if type(exec_argv) ~= "function" then
    error("browser-qa: browser-adapter-unavailable: exec_argv is required", 0)
  end
  return exec_argv(spec)
end

function M.production_handles()
  return {
    browser = adapter.new(production_runner),
  }
end

local function validate_department(department)
  if type(department) ~= "table"
    or type(department.spec) ~= "table"
    or type(department.pipeline) ~= "function" then
    error("browser-qa: invalid-department: make_department must return spec and pipeline", 0)
  end
end

local function make_with_pipeline_restore(make_department, handles)
  local previous_pipeline = _G.pipeline
  local ok, department_or_error = pcall(make_department, handles)
  if not ok then
    _G.pipeline = previous_pipeline
    error(department_or_error, 0)
  end
  local captured_pipeline = _G.pipeline
  if type(captured_pipeline) == "function" and captured_pipeline ~= previous_pipeline then
    department_or_error.pipeline = captured_pipeline
  end
  local ok_validate, validation_error = pcall(validate_department, department_or_error)
  if not ok_validate then
    _G.pipeline = previous_pipeline
    error(validation_error, 0)
  end
  _G.pipeline = previous_pipeline
  return department_or_error
end

function M.install(make_department)
  assert(type(make_department) == "function", "browser-qa: install requires make_department")
  local department = make_with_pipeline_restore(make_department, M.production_handles())
  _G.pipeline = department.pipeline
  department.make_department = function(handles)
    return make_with_pipeline_restore(make_department, handles)
  end
  return department
end

return M
