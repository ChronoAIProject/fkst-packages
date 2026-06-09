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

local function run_cmd(cmd, error_class)
  local result = exec_sync({ cmd = cmd, timeout = 30 })
  if result.exit_code ~= 0 then
    error("github-devloop: " .. error_class .. " failed: " .. tostring(result.stderr))
  end
  return result
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

  local listed = run_cmd(core.gh_issue_list_observe_cmd(repo, OBSERVE_LIMIT), "gh observe issue list")
  local entities = {}
  for _, issue in ipairs(core.parse_issue_list_observe(listed.stdout)) do
    local issue_number = tostring(issue.number or "")
    if core.issue_ref_round_trips(repo, issue_number) then
      local proposal_id = core.proposal_id(repo, issue_number)
      local viewed = run_cmd(core.gh_issue_view_observe_cmd(repo, issue_number), "gh observe issue view")
      local current = core.parse_issue_view_observe(viewed.stdout)
      core.log_forged_markers("observe_scan", proposal_id, current.comments)
      if core.should_observe_entity(current.labels, current.comments, proposal_id) then
        table.insert(entities, core.observe_entity_summary(repo, issue_number, current))
      end
    end
  end

  local payload = core.build_state_snapshot_payload(repo, entities, snapshot_time(event))
  core.log_raise("observe_scan", "github-devloop/observe", "devloop_state_snapshot", payload)
end

return M
