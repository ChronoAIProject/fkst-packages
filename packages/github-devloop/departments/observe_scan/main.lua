local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_observe_tick" },
  produces = { "devloop_state_snapshot" },
  fanout = { "devloop_observe_tick" },
  stall_window = "1m",
}

local OBSERVE_LIMIT = 100

local function read_repo()
  local repo = core.devloop_config().repo
  if repo == nil or not core.issue_ref_round_trips(repo, 1) then
    return nil
  end
  return repo
end

local function snapshot_time(event)
  if type(event) == "table" and event.ts ~= nil and tostring(event.ts) ~= "" then
    return tostring(event.ts)
  end
  return tostring(now())
end

function pipeline(event)
  core.log_entry("observe_scan", event, "github-devloop/observe", "tick")
  core.assert_trusted_bot_configured()

  local repo = read_repo()
  if repo == nil then
    core.log_cas_decision("observe_scan", "github-devloop/observe", { state = nil, version = nil }, "tick", "snapshot", "skip-invalid-repo", "FKST_GITHUB_REPO is missing or invalid")
    return
  end

  local payload = core.build_state_snapshot_payload(repo, snapshot_time(event), core.observe_scope(OBSERVE_LIMIT, OBSERVE_LIMIT))
  core.log_raise("observe_scan", "github-devloop/observe", "devloop_state_snapshot", payload)
end

return M
