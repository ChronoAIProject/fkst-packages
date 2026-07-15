local inspect_caps = require("inspect_caps")
local ports_lib = require("browser_ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "browser_qa_request" },
  published_seam = { "browser_qa_request" },
  produces = { "browser_qa_result", "github-proxy.github_pr_comment_request" },
  fanout = { "browser_qa_result" },
  stall_window = "2m",
  retry = false,
}

local function is_request(event)
  local queue = tostring(event and event.queue or "")
  return queue == "browser_qa_request" or queue == "browser-qa.browser_qa_request"
end

local function done(event)
  if not is_request(event) then
    error("browser-qa: unknown-queue: " .. tostring(event and event.queue), 0)
  end
  return false
end

local function make_department(ports)
  ports = ports or {}
  local browser = ports.browser
  local caps = ports.caps or inspect_caps
  if type(browser) ~= "table" or type(browser.navigate) ~= "function" then
    error("browser-qa: browser-port-unavailable: navigate is required", 0)
  end

  local function act(event)
    if not is_request(event) then
      error("browser-qa: unknown-queue: " .. tostring(event and event.queue), 0)
    end
    local request = caps.validate_request(event.payload)
    local navigation, adapter_error = browser.navigate(request.url, request.viewport)
    if navigation == nil then
      error(caps.adapter_error_message(adapter_error), 0)
    end
    navigation = caps.validate_navigation(navigation)
    if not navigation.blank_render then
      return
    end
    raise("browser_qa_result", caps.failed_result(request, navigation))
    raise("github-proxy.github_pr_comment_request", caps.comment_request(request, navigation))
  end

  local department = saga.department(spec, {
    done = done,
    act = act,
    name = "inspect",
  })
  department.ports = ports
  return department
end

return ports_lib.install(make_department)
