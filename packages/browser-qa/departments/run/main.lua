local core = require("core")
local env = require("workflow.env")
local ports_lib = require("forge.ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "browser_qa_request" },
  published_seam = { "browser_qa_request" },
  produces = { "browser_qa_result" },
  fanout = { "browser_qa_result" },
  stall_window = "5m",
  retry = false,
}

local allowed_env = {
  BROWSER_QA_RUNNER = true,
  BROWSER_QA_COMMAND = true,
  BROWSER_QA_TIMEOUT_SECONDS = true,
  BROWSER_QA_WORKDIR = true,
}

local function read_env_command(name)
  if not allowed_env[name] then
    error("browser-qa: invalid-env-name: env name is not allowed", 0)
  end
  return 'printf %s "$' .. name .. '"'
end

local default_read_env = env.read_env(read_env_command, { propagate_exec_errors = true })

local function is_request_queue(event)
  local queue = tostring(event and event.queue or "")
  return queue == "browser_qa_request" or queue == "browser-qa.browser_qa_request"
end

local function done(event)
  if not is_request_queue(event) then
    error("browser-qa: unknown-queue: " .. tostring(event and event.queue), 0)
  end
  return false
end

local function env_values(read_env)
  local values = {}
  for name, _ in pairs(allowed_env) do
    values[name] = read_env(name)
  end
  return values
end

local function result_from_failure(payload, err)
  return core.result_payload(payload, {
    stdout = "",
    stderr = tostring(err),
    exit_code = 1,
    timed_out = false,
  }, nil)
end

local function make_department(ports)
  ports = ports or {}
  local read_env = ports.read_env or default_read_env
  local run_exec = ports.exec_argv or exec_argv

  local function act(event)
    if not is_request_queue(event) then
      error("browser-qa: unknown-queue: " .. tostring(event and event.queue), 0)
    end
    local payload = event.payload or {}
    local request = core.normalize_request(payload)
    local config = core.runner_config(env_values(read_env))
    if type(run_exec) ~= "function" then
      error("browser-qa: exec-argv-unavailable: exec_argv is required", 0)
    end
    log.info(
      "browser-qa: run request_id="
        .. tostring(request.request_id)
        .. " runner="
        .. tostring(config.runner)
        .. " target_url="
        .. tostring(request.target_url)
    )
    local ok, result = pcall(function()
      return run_exec({
        argv = config.argv,
        cwd = config.workdir,
        env = {
          BROWSER_QA_TARGET_URL = request.target_url,
          BROWSER_QA_REPORT_ARTIFACT = request.report_artifact,
        },
        timeout = config.timeout_seconds,
      })
    end)
    local result_payload = nil
    if ok then
      result_payload = core.result_payload(payload, result, config.timeout_seconds)
    else
      result_payload = result_from_failure(payload, result)
      result_payload.timeout_seconds = config.timeout_seconds
    end
    raise("browser_qa_result", result_payload)
  end

  local department = saga.department(spec, {
    done = done,
    act = act,
    name = "run",
  })
  department.ports = ports
  return department
end

return ports_lib.install(make_department)
