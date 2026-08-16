local M = {}
local strings = require("contract.strings")

local codex_run_counter = 0
local ulid_alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local ulid_prefix = "01ARZ3NDEKTSV4RRFFQ6"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function ulid_suffix(value)
  local encoded = {}
  for index = 6, 1, -1 do
    local offset = (value % 32) + 1
    encoded[index] = ulid_alphabet:sub(offset, offset)
    value = math.floor(value / 32)
  end
  return table.concat(encoded)
end

local function next_codex_run_id()
  codex_run_counter = codex_run_counter + 1
  return "codex-" .. ulid_prefix .. ulid_suffix(codex_run_counter)
end

function M.escape_json_string(value, unicode_escape_format)
  return tostring(value)
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\f", "\\f")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
    :gsub("[%z\1-\31]", function(char)
      return string.format(unicode_escape_format, string.byte(char))
    end)
end

function M.codex_agent_message_jsonl(message)
  if type(message) ~= "string" then
    error("testkit-internal: codex-agent-message-invalid: fixture message must be a string")
  end
  return '{"type":"item.completed","item":{"type":"agent_message","text":'
    .. strings.json_string(message)
    .. "}}\n"
end

local function json_value(value)
  if type(value) == "number" then
    return tostring(value)
  end
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  if value == nil then
    return "null"
  end
  if type(value) ~= "string" then
    error("testkit-internal: codex-status-value-invalid: fixture records require scalar values")
  end
  return strings.json_string(value)
end

local function json_object(record)
  local parts = {}
  for key, value in pairs(record or {}) do
    table.insert(parts, strings.json_string(key) .. ":" .. json_value(value))
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

local function write_file(path, body)
  local handle = assert(io.open(path, "w"))
  handle:write(body)
  handle:close()
end

function M.seed_running_codex_status(run_opts, source_record)
  local root = run_opts and run_opts.env and run_opts.env.FKST_RUNTIME_LOG_DIR
  if root == nil or root == "" then
    error("testkit-internal: codex-status-log-dir-missing: FKST_RUNTIME_LOG_DIR is required")
  end

  local record = {}
  for key, value in pairs(source_record or {}) do
    record[key] = value
  end
  record.run_id = next_codex_run_id()

  local dir = root .. "/codex"
  local path = dir .. "/fixture-" .. record.run_id .. ".log"
  local release_path = path .. ".release"
  os.remove(release_path)

  local script = [[
import fcntl
import pathlib
import sys
import time

log_path, release_path = sys.argv[1:3]
pathlib.Path(log_path).parent.mkdir(parents=True, exist_ok=True)
with open(log_path, "a+", encoding="utf-8") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    print("ready", flush=True)
    while not pathlib.Path(release_path).exists():
        try:
            print(".", end="", flush=True)
        except BrokenPipeError:
            break
        time.sleep(0.1)
]]
  local command = "python3 -c " .. shell_quote(script)
    .. " " .. shell_quote(path)
    .. " " .. shell_quote(release_path)
  local process = assert(io.popen(command, "r"))
  if process:read("*l") ~= "ready" then
    process:close()
    error("testkit-internal: codex-status-witness-start-failed: lock witness did not become ready")
  end

  local file = assert(io.open(path, "a"))
  file:write("CODEX_STATUS:" .. json_object(record) .. "\n")
  file:close()

  local released = false
  return function()
    if released then
      return
    end
    released = true
    write_file(release_path, "release\n")
    local ok, reason, code = process:close()
    os.remove(release_path)
    if ok ~= true then
      error("testkit-internal: codex-status-witness-stop-failed: "
        .. tostring(reason) .. " " .. tostring(code))
    end
  end
end

local function capture_raises(fn)
  local old_raise = raise
  local raised = {}
  raise = function(queue, payload)
    table.insert(raised, {
      queue = queue,
      payload = payload,
    })
  end
  local ok, result = pcall(fn)
  raise = old_raise
  if ok then
    return result, raised, nil
  end
  return nil, raised, { error = result }
end

local function writes_from_department(dept)
  local ports = type(dept) == "table" and dept.ports or nil
  local model = type(dept) == "table" and dept.model or nil
  if type(model) == "table" and type(model.writes) == "table" then
    return model.writes
  end
  if type(ports) == "table" then
    for _, port in pairs(ports) do
      if type(port) == "table" and type(port._model) == "table" and type(port._model.writes) == "table" then
        return port._model.writes
      end
    end
  end
  return {}
end

local function capture_pipeline(dept, event)
  assert(type(dept) == "table", "dept must be a table")
  assert(type(dept.pipeline) == "function", "dept must expose .pipeline")
  local result, raises, failure = capture_raises(function()
    return dept.pipeline(event)
  end)
  return result, raises, failure, writes_from_department(dept)
end

-- Expose, don't swallow (#710 Finding 2): a pipeline error under run_fake fails
-- the test loudly. The previous run_fake returned a {failure} shape on error, so
-- a test that forgot to assert `failure == nil` passed even when the pipeline
-- errored — a false-green that undercuts the #633 "no false-green" promise.
-- Tests that intend to assert an error use run_fake_expecting_failure.
function M.run_fake(dept, event)
  local result, raises, failure, writes = capture_pipeline(dept, event)
  if failure ~= nil then
    error(failure.error, 0)
  end
  return {
    result = result,
    raises = raises,
    writes = writes,
    failure = nil,
  }
end

function M.run_fake_expecting_failure(dept, event)
  local result, raises, failure, writes = capture_pipeline(dept, event)
  assert(failure ~= nil, "run_fake_expecting_failure: pipeline was expected to error but did not")
  return {
    result = result,
    raises = raises,
    writes = writes,
    failure = failure,
  }
end

function M.run_fake_outcome(dept, event)
  local result, raises, failure, writes = capture_pipeline(dept, event)
  return {
    exit_code = failure == nil and 0 or 1,
    error = failure and failure.error or nil,
    result = result,
    raises = raises,
    writes = writes,
    failure = failure,
  }
end

-- Runs `fn` with fkst.codex_runs reporting `running`, restoring the original on every path so a
-- failing body cannot leak a patched harness into later tests. Six suites each carried this.
-- fkst is touched only when called, so this module still takes no harness global at load time.
function M.with_codex_runs(running, fn)
  local original = fkst.codex_runs
  fkst.codex_runs = function()
    return { running = running or {}, recent = {} }
  end
  local ok, err = pcall(fn)
  fkst.codex_runs = original
  if not ok then
    error(err)
  end
end

-- Runs `command` through the shell, capturing stdout and stderr together, and reports whether it
-- succeeded. Eight suites across six packages carried this. io is a Lua stdlib global reached at
-- call time, so this module still takes no harness global at load.
function M.command_output(command)
  local handle = assert(io.popen(command .. " 2>&1"))
  local output = handle:read("*a")
  local ok = handle:close()
  return output, ok ~= false and ok ~= nil
end

-- Runs `fn` with log.warn recording instead of emitting, restoring the original on every path so a
-- failing body cannot leak a patched logger into later tests. Returns the body's result and the
-- captured messages. Four suites across four packages carried this under two names, differing only
-- in the accumulator's name. log is reached at call time, so this module still takes no harness
-- global at load.
function M.capture_warn_logs(fn)
  local previous_warn = log.warn
  local logs = {}
  log.warn = function(message)
    table.insert(logs, tostring(message))
  end
  local ok, result = pcall(fn)
  log.warn = previous_warn
  if not ok then
    error(result, 0)
  end
  return result, logs
end

return M
