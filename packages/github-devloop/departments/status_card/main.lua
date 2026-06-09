local core = require("core")

local M = {}

M.spec = {
  consumes = { "devloop_status_card_tick" },
  produces = { "github-proxy.github_issue_comment_request" },
  fanout = { "devloop_status_card_tick" },
  stall_window = "30s",
}

local STATUS_CARD_LIMIT = 100

local function read_repo()
  local repo = core.devloop_config().repo
  if repo == nil or not core.issue_ref_round_trips(repo, 1) then
    return nil
  end
  return repo
end

local function source_ref(repo, issue_number)
  return {
    kind = "external",
    ref = tostring(repo) .. "#issue/" .. tostring(issue_number),
  }
end

function pipeline(event)
  core.log_entry("status_card", event, "github-devloop/status-card", "tick")
  core.assert_trusted_bot_configured()

  local repo = read_repo()
  if repo == nil then
    core.log_cas_decision("status_card", "github-devloop/status-card", { state = nil, version = nil }, "tick", "status-card", "skip-invalid-repo", "FKST_GITHUB_REPO is missing or invalid")
    return
  end

  local list = exec_sync({ cmd = core.gh_issue_list_status_card_cmd(repo, STATUS_CARD_LIMIT), timeout = 30 })
  if list.exit_code ~= 0 then
    error("github-devloop: gh issue status-card list failed: " .. tostring(list.stderr))
  end

  for _, issue in ipairs(core.parse_issue_list_intake(list.stdout)) do
    local issue_number = tostring(issue.number or "")
    if core.issue_ref_round_trips(repo, issue_number) then
      local proposal_id = core.proposal_id(repo, issue_number)
      local view = exec_sync({ cmd = core.gh_issue_view_status_card_cmd(repo, issue_number), timeout = 30 })
      if view.exit_code ~= 0 then
        error("github-devloop: gh issue status-card view failed: " .. tostring(view.stderr))
      end
      local current_issue = core.parse_issue_view_status_card(view.stdout)
      core.log_forged_markers("status_card", proposal_id, current_issue.comments)
      local current = core.current_state(current_issue.comments, proposal_id)
      if current.state ~= nil and not core.is_status_card_terminal_state(current.state) then
        local request = core.build_status_card_comment_request(repo, issue_number, proposal_id, current, source_ref(repo, issue_number))
        core.log_apply("status_card", proposal_id, nil, current.version, { add = {}, remove = {} }, {
          "github-proxy.github_issue_comment_request",
        })
        core.log_raise("status_card", proposal_id, "github-proxy.github_issue_comment_request", request)
      else
        core.log_cas_decision("status_card", proposal_id, current, "active", "status-card", "skip-terminal-or-unmanaged", "no active trusted state marker")
      end
    end
  end
end

return M
