local M = {}

local source_ref = require("contract.source_ref")
local strings = require("contract.strings")

local limits = {
  key = 240,
  source_ref = 240,
  url = 500,
  artifact = 260,
  summary = 1000,
  command = 1000,
  workdir = 260,
}

local forbidden_request_fields = {
  argv = true,
  command = true,
  cmd = true,
  body = true,
  diff = true,
  content = true,
  files = true,
}

local function trim(value)
  return strings.trim(value)
end

local function fail(message)
  error("browser-qa: validation: " .. tostring(message), 0)
end

local function require_bounded_string(value, limit, field)
  if not strings.is_bounded_string(value, limit) then
    fail("invalid-request-field: " .. tostring(field))
  end
  if tostring(value):find("[%c]") ~= nil then
    fail("invalid-request-field: " .. tostring(field))
  end
  return value
end

local function has_forbidden_field(payload)
  for field, _ in pairs(forbidden_request_fields) do
    if payload[field] ~= nil then
      return field
    end
  end
  return nil
end

local function loopback_target(url)
  if type(url) ~= "string" or url == "" or #url > limits.url then
    return false
  end
  if url:find("[%c%s]") ~= nil then
    return false
  end
  local scheme, rest = url:match("^(https?)://(.+)$")
  if scheme ~= "http" then
    return false
  end
  local host = nil
  local after_host = nil
  if rest:sub(1, 1) == "[" then
    host, after_host = rest:match("^(%[[^%]]+%])(.*)$")
  else
    host, after_host = rest:match("^([^/:?#]+)(.*)$")
  end
  if host == nil then
    return false
  end
  local next_char = after_host:sub(1, 1)
  if next_char ~= "" and next_char ~= ":" and next_char ~= "/" and next_char ~= "?" and next_char ~= "#" then
    return false
  end
  return host == "127.0.0.1" or host == "localhost" or host == "[::1]"
end

local function safe_artifact_path(value)
  if not strings.is_path_safe_key(value, limits.artifact) then
    return false
  end
  return tostring(value):find("^browser%-qa/") == 1
end

function M.normalize_request(payload)
  if type(payload) ~= "table" then
    fail("invalid-request: payload must be a table")
  end
  local forbidden = has_forbidden_field(payload)
  if forbidden ~= nil then
    fail("forbidden-request-field: " .. forbidden)
  end
  if payload.schema ~= "browser-qa.request.v1" then
    fail("unsupported-schema: " .. tostring(payload.schema))
  end
  if payload.runner ~= "playwright" then
    fail("unsupported-runner: " .. tostring(payload.runner))
  end
  if not loopback_target(payload.target_url) then
    fail("invalid-target-url: target_url must be an http loopback URL")
  end
  if not safe_artifact_path(payload.report_artifact) then
    fail("invalid-report-artifact: report_artifact must be a browser-qa relative path")
  end
  if not source_ref.has_bounded_source_ref(payload.source_ref, limits.source_ref) then
    fail("invalid-source-ref: source_ref must be bounded")
  end
  local normalized_source_ref = {
    kind = payload.source_ref.kind,
    ref = payload.source_ref.ref,
  }
  return {
    schema = "browser-qa.request.v1",
    request_id = require_bounded_string(payload.request_id, limits.key, "request_id"),
    dedup_key = require_bounded_string(payload.dedup_key, limits.key, "dedup_key"),
    runner = "playwright",
    target_url = payload.target_url,
    report_artifact = payload.report_artifact,
    source_ref = normalized_source_ref,
  }
end

local function split_command(command)
  local text = trim(command)
  if text == "" or #text > limits.command then
    fail("invalid-runner-command: BROWSER_QA_COMMAND is required")
  end
  if text:find("[;&|`$<>(){}%[%]\n\r]") ~= nil then
    fail("invalid-runner-command: shell metacharacters are forbidden")
  end
  local argv = {}
  for part in text:gmatch("%S+") do
    table.insert(argv, part)
  end
  if #argv == 0 then
    fail("invalid-runner-command: command argv is empty")
  end
  return argv
end

local function timeout_seconds(value)
  local raw = trim(value)
  if raw == "" then
    return 120
  end
  local parsed = tonumber(raw)
  if parsed == nil or parsed < 1 or parsed > 600 or math.floor(parsed) ~= parsed then
    fail("invalid-timeout: BROWSER_QA_TIMEOUT_SECONDS must be an integer from 1 to 600")
  end
  return parsed
end

local function workdir(value)
  local text = trim(value)
  if text == "" then
    return "."
  end
  if text == "." then
    return text
  end
  if not strings.is_path_safe_key(text, limits.workdir) then
    fail("invalid-workdir: BROWSER_QA_WORKDIR must be a safe relative path")
  end
  return text
end

function M.runner_config(env_values)
  local env = env_values or {}
  local runner = trim(env.BROWSER_QA_RUNNER or "")
  if runner == "" then
    runner = "playwright"
  end
  if runner ~= "playwright" then
    fail("unsupported-runner: " .. runner)
  end
  return {
    runner = runner,
    argv = split_command(env.BROWSER_QA_COMMAND),
    timeout_seconds = timeout_seconds(env.BROWSER_QA_TIMEOUT_SECONDS),
    workdir = workdir(env.BROWSER_QA_WORKDIR),
  }
end

local function bounded_summary(value)
  local text = tostring(value or "")
  text = text:gsub("\r", "\\r"):gsub("\n", "\\n")
  if #text > limits.summary then
    return text:sub(1, limits.summary)
  end
  return text
end

function M.result_payload(request_payload, command_result, timeout)
  local request = M.normalize_request(request_payload)
  local result = command_result or {}
  local exit_code = tonumber(result.exit_code)
  if exit_code == nil then
    exit_code = 1
  end
  local timed_out = result.timed_out == true
  return {
    schema = "browser-qa.result.v1",
    request_id = request.request_id,
    dedup_key = request.dedup_key,
    runner = request.runner,
    target_url = request.target_url,
    decision = (exit_code == 0 and not timed_out) and "pass" or "fail",
    exit_code = exit_code,
    timed_out = timed_out,
    timeout_seconds = tonumber(timeout) or nil,
    report_artifact = request.report_artifact,
    stdout_summary = bounded_summary(result.stdout),
    stderr_summary = bounded_summary(result.stderr),
    source_ref = {
      kind = request.source_ref.kind,
      ref = request.source_ref.ref,
    },
  }
end

return M
