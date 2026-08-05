local child_disposition_reconcile = require("child_disposition_reconcile")
local github_factory = require("devloop.github_factory")
local ports = require("forge.ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow_child_disposition_request" },
  published_seam = { "workflow_child_disposition_request" },
  produces = {},
  retry = { max_attempts = 12, base = "5s", cap = "30s" },
  stall_window = "2m",
}

local function make_department(handles)
  local department = saga.department(spec, child_disposition_reconcile.handlers(nil, {
    ports = handles,
  }))
  department.ports = handles
  return department
end

return ports.install(make_department, github_factory.github_options(exec_sync))
