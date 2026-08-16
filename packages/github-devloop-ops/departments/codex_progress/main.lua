local progress = require("core.codex_progress")
local saga = require("workflow.saga")

local spec = {
  consumes = { "devloop_codex_progress_tick" },
  produces = { "github-proxy.github_issue_comment_request" },
  retry = {},
  stall_window = "2m",
}

local function done(_event)
  return false
end

local function emit(rows, project)
  for _, row in ipairs(rows) do
    local projected = project(row)
    if projected ~= nil then
      raise("github-proxy.github_issue_comment_request", projected.request)
    end
  end
end

local function act(_event)
  if type(fkst) ~= "table" or type(fkst.codex_runs) ~= "function" then
    error("github-devloop-ops: codex-progress-unavailable: fkst.codex_runs is required")
  end
  local observed = fkst.codex_runs()
  if type(observed) ~= "table"
    or type(observed.running) ~= "table"
    or type(observed.recent) ~= "table" then
    error("github-devloop-ops: codex-progress-invalid: fkst.codex_runs returned invalid run sets")
  end
  -- One observation instant per tick, shared by every running card in this pass.
  local card_refreshed_at = os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(now()) or os.time())
  emit(observed.running, function(row)
    return progress.project_running_row(row, card_refreshed_at)
  end)
  emit(observed.recent, progress.project_terminal_row)
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "codex_progress",
})
