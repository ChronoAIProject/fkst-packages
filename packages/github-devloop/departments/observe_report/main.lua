local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_state_snapshot" },
  produces = {},
  stall_window = "30s",
}

local function run_cmd(cmd, error_class)
  local result = exec_sync({ cmd = cmd, timeout = 30 })
  if result.exit_code ~= 0 then
    error("github-devloop: " .. error_class .. " failed: " .. tostring(result.stderr))
  end
  return result
end

function pipeline(event)
  local payload = event and event.payload or {}
  core.log_entry("observe_report", event, "github-devloop/observe", payload and payload.dedup_key or "snapshot")
  local repo = tostring(payload.repo or "")
  if repo == "" or not core.issue_ref_round_trips(repo, 1) then
    error("github-devloop: invalid state snapshot repo")
  end
  local source_ref = type(payload.source_ref) == "table" and payload.source_ref or {}
  if source_ref.kind ~= "external" or source_ref.ref ~= repo .. "#state-snapshot" then
    error("github-devloop: invalid state snapshot source_ref")
  end
  local snapshot = {
    schema = payload.schema,
    repo = repo,
    observed_at = payload.observed_at,
    dedup_key = payload.dedup_key,
    source_ref = payload.source_ref,
    scope = payload.scope,
    artifact = payload.artifact,
    entities = core.collect_state_snapshot(repo, payload.scope, run_cmd),
  }
  for _, line in ipairs(core.state_snapshot_report_lines(snapshot)) do
    core.log_line("info", "observe_report", "github-devloop/observe", "SNAPSHOT", { line })
  end
end

return M
