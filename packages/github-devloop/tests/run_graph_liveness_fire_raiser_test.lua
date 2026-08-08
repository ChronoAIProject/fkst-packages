local base_ids = require("devloop.base_ids")
local devloop_base = require("devloop.base")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")

local t = h.t
local core = h.core
local repo = "raiser-owner/raiser-repo"
local issue_number = 4242
local proposal_id = base_ids.proposal_id(repo, issue_number)
local version = "consensus-github-devloop/issue/raiser-owner/raiser-repo/4242/2026-06-03T01-02-03Z"

local function mock_env()
  t.mock_command(devloop_base.read_env_command("FKST_GITHUB_REPO"), {
    stdout = repo,
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(devloop_base.read_env_command("FKST_GITHUB_BOT_LOGIN"), {
    stdout = "fkst-test-bot",
    stderr = "",
    exit_code = 0,
  })
end

local function mock_projection_mismatch()
  t.mock_command(core.gh_issue_list_observe_cmd(repo), {
    stdout = '[{"number":4242,"state":"open","updated_at":"2026-06-03T01:02:03Z"}]\n',
    stderr = "",
    exit_code = 0,
  })
  entity_read_mocks.mock_issue_read_forms(t, {
    repo = repo,
    number = issue_number,
    title = "Fire raiser projection mismatch",
    body = "",
    state = "OPEN",
    updated_at = "2026-06-03T01:02:03Z",
    labels = { "fkst-dev:enabled", "fkst-dev:thinking" },
    comments = { h.state_comment(proposal_id, "declined", version) },
    assignees = { "fkst-test-bot" },
    times = 1,
  })
end

return {
  test_fire_raiser_liveness_poll_reinjects_terminal_projection_mismatch = function()
    mock_env()
    mock_projection_mismatch()

    local trace = t.fire_raiser("liveness_poll")

    t.eq(trace.source_ref.kind, "cron")
    t.eq(trace.source_payload.raiser, "github-devloop.liveness_poll")
    t.eq(trace.routed_to[1], "github-devloop.liveness_scan")
    if trace.consumer_result.status ~= "accepted" then
      error(trace.consumer_result.message or "fire_raiser consumer failed")
    end
    t.eq(trace.consumer_result.status, "accepted")
    local reinjected = nil
    local raised_facts = {}
    for _, raised in ipairs(trace.raised) do
      local source_ref = raised.payload.source_ref
      table.insert(raised_facts, tostring(raised.queue) .. "@" .. tostring(source_ref and source_ref.ref))
      if raised.queue == "github-devloop.devloop_observe_issue"
        and source_ref ~= nil
        and source_ref.ref == repo .. "#issue/" .. tostring(issue_number) then
        reinjected = raised
      end
    end
    t.is_true(reinjected ~= nil, "raised=" .. table.concat(raised_facts, ","))
    t.eq(reinjected.payload.type, "issue")
    t.eq(reinjected.payload.source, "liveness-scan")
    t.eq(reinjected.payload.source_ref.kind, "external")
    t.eq(reinjected.payload.source_ref.ref, repo .. "#issue/" .. tostring(issue_number))
  end,
}
