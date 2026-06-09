local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_state_snapshot" },
  produces = {},
  stall_window = "30s",
}

function pipeline(event)
  local payload = event and event.payload or {}
  core.log_entry("observe_report", event, "github-devloop/observe", payload and payload.dedup_key or "snapshot")
  for _, line in ipairs(core.state_snapshot_report_lines(payload)) do
    core.log_line("info", "observe_report", "github-devloop/observe", "SNAPSHOT", { line })
  end
end

return M
