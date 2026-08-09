local child_transfer = require("core.child_transfer")
local devloop_base = require("devloop.base")
local devloop_logging = require("devloop.logging")
local ports_seam = require("forge.ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow_child_transfer_request" },
  published_seam = { "workflow_child_transfer_request" },
  produces = {},
  stall_window = "2m",
}

local function event_queue_matches(event)
  local queue = tostring(event and event.queue or "")
  return queue == child_transfer.QUEUE
    or queue:match("%." .. child_transfer.QUEUE .. "$") ~= nil
end

local function make_department(ports)
  local transfer = child_transfer.new(ports)
  local function act(event)
    if not event_queue_matches(event) then
      error("github-devloop-workflow: unsupported-consumed-queue: " .. tostring(event and event.queue or ""))
    end
    local payload = event and event.payload
    devloop_logging.log_entry(
      child_transfer.DEPT,
      event,
      type(payload) == "table" and payload.origin or "unknown",
      type(payload) == "table" and payload.dedup_key or "unknown"
    )
    return transfer.transfer(payload)
  end

  local previous_pipeline = _G.pipeline
  local department = saga.department(spec, {
    done = function()
      return false
    end,
    act = act,
    wrap = devloop_logging.wrap_pipeline_failure,
    name = child_transfer.DEPT,
  })
  department.pipeline = _G.pipeline
  _G.pipeline = previous_pipeline
  return department
end

local M = ports_seam.install(
  make_department,
  ports_seam.github_author_options(devloop_base.read_env, child_transfer.DEPT, {
    bot_login_env = "FKST_GITHUB_BOT_LOGIN",
  })
)
M.make_department = make_department
_G.pipeline = M.pipeline

return M
