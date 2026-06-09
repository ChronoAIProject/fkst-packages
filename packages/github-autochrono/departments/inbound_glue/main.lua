local core = require("core")

local M = {}

M.spec = {
  consumes = { "github-proxy.github_entity_changed" },
  produces = { "autochrono.issue" },
  fanout = { "github-proxy.github_entity_changed" },
  stall_window = "30s",
}

function pipeline(event)
  local payload = event.payload or {}
  if payload.type ~= "issue" then
    return
  end

  local view = exec_sync({ cmd = core.gh_issue_view_source_cmd(payload.repo, payload.number), timeout = 30 })
  if view.exit_code ~= 0 then
    error("github-autochrono glue: gh issue source view failed: " .. tostring(view.stderr))
  end
  payload.source_text_ref = core.write_issue_source_snapshot(
    core.read_env("FKST_RUNTIME_ROOT"),
    payload.repo,
    payload.number,
    payload.updated_at,
    view.stdout
  )

  raise("autochrono.issue", core.entity_to_issue(payload))
end

return M
