local base_ids = require("devloop.base_ids")
local config = require("devloop.config")
local core = require("core")
local devloop_base = require("devloop.base")
local ports = require("forge.ports")
local saga = require("workflow.saga")

local spec = {
  consumes = { "triage_patrol_receipt_request" },
  produces = { "github-proxy.github_issue_comment_request" },
  stall_window = "10m",
}

local function make_department(handles)
  local department = saga.department(spec, {
    done = function()
      return false
    end,
    act = function(event)
      local repo = core.require_triage_patrol_repo()
      local payload = event.payload or {}
      core.validate_triage_patrol_receipt_request(payload, repo)
      local mode = config.write_mode()
      if mode ~= "real" then
        log.info("github-devloop-ops dept=triage_patrol_receipt tag=TRIAGE_RECEIPT_DRY_RUN"
          .. " snapshot=" .. tostring(payload.snapshot or "")
          .. " entries=" .. tostring(payload.entries or ""))
      end
      local host_login = core.require_triage_patrol_host_login()
      with_lock("github-devloop/triage-patrol-receipt/" .. base_ids.safe_repo(repo), function()
        local request = core.reconcile_triage_patrol_receipt(
          handles.github,
          repo,
          host_login,
          payload,
          mode,
          core.observability_limits().call_timeout
        )
        if request ~= nil then
          raise("github-proxy.github_issue_comment_request", request)
        end
      end)
    end,
    wrap = core.wrap_pipeline_failure,
    name = "triage_patrol_receipt",
  })
  department.ports = handles
  return department
end

return ports.install(make_department, ports.github_author_options(
  devloop_base.read_env,
  "github-devloop-ops.triage_patrol_receipt",
  { bot_login_env = "FKST_GITHUB_BOT_LOGIN" }
))
