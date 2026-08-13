local config = require("devloop.config")
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

local function act(_event)
  if not progress.publication_enabled(config.write_mode()) then
    log.info("github-devloop-ops: codex progress real-write rollout is blocked pending lifecycle convergence")
    return
  end
  if type(fkst) ~= "table" or type(fkst.codex_runs) ~= "function" then
    error("github-devloop-ops: codex-progress-unavailable: fkst.codex_runs is required")
  end
  local observed = fkst.codex_runs()
  if type(observed) ~= "table" or type(observed.running) ~= "table" then
    error("github-devloop-ops: codex-progress-invalid: fkst.codex_runs returned an invalid running set")
  end
  for _, row in ipairs(observed.running) do
    local projected = progress.project_running_row(row)
    if projected ~= nil then
      raise("github-proxy.github_issue_comment_request", projected.request)
    end
  end
end

return saga.department(spec, {
  done = done,
  act = act,
  name = "codex_progress",
})
