local consensus_core = require("consensus.core")
local core = require("core")
local entity_read_mocks = require("tests.entity_read_mock_helpers")
local h = require("tests.devloop_helpers")

local t = h.t
local proposal_id = "github-devloop/issue/owner/repo/42"
local version = "github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"

local function mock_consensus_approval()
  for _ = 1, 16 do
    t.mock_command('printf %s "$FKST_RUNTIME_ROOT"', {
      stdout = "/tmp/fkst-packages-test/github-devloop/consensus-result-production-wiring",
      stderr = "",
      exit_code = 0,
    })
  end
  for _ = 1, #consensus_core.angles({}) do
    t.mock_command(consensus_core.checkout_root_exists_cmd("."), {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("mkdir -p", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("codex exec", {
      stdout = "⟦FKST:VERDICT⟧ approve\n⟦FKST:REPLY⟧ managed author is admissible.\n",
      stderr = "",
      exit_code = 0,
    })
  end
end

local function count_codex_calls(from_index)
  local count = 0
  for index, call in ipairs(t.command_calls()) do
    if index > from_index and tostring(call.rendered or ""):find("codex exec", 1, true) ~= nil then
      count = count + 1
    end
  end
  return count
end

return {
  test_managed_author_reaches_consensus_through_production_wiring = function()
    mock_consensus_approval()
    entity_read_mocks.mock_issue_read_with_defaults(t,
      { "fkst-dev:enabled", "fkst-dev:thinking" },
      {
        {
          body = core.state_marker(proposal_id, "thinking", version),
          author_login = "fkst-test-bot",
          created_at = "2026-06-03T01:02:03Z",
        },
      },
      {
        author_login = "managed-peer",
        assignees = { "fkst-test-bot" },
        times = 1,
      })
    t.mock_command(core.gh_blocked_by_cmd("owner/repo", 42), {
      stdout = '{"data":{"repository":{"issue":{"blockedBy":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}\n',
      stderr = "",
      exit_code = 0,
    })

    local call_start = #t.command_calls()
    local result = h.run_department("departments/consensus_result/main.lua", {
      queue = "devloop_consensus_request",
      payload = {
        schema = "consensus.proposal.v1",
        verdict_mode = "converge",
        proposal_id = proposal_id,
        title = "Judge issue 42",
        body = "Decide whether issue 42 is ready.",
        worktree = ".",
        dedup_key = version,
        effect_version = version,
        source_ref = { kind = "external", ref = "owner/repo#issue/42" },
      },
    }, h.opts("consensus-result-production-managed-author", {
      env = {
        FKST_DEVLOOP_MANAGED_BOT_LOGINS = "managed-peer",
        FKST_GITHUB_AUTHORIZED_LOGINS = "",
      },
    }))

    t.eq(result.exit_code, 0)
    t.eq(count_codex_calls(call_start), #consensus_core.angles({}))
    local outcome = h.find_raise(result.raises, "github-proxy.github_issue_comment_request")
    t.is_true(outcome ~= nil)
    t.is_true(outcome.payload.body:find("github-devloop decision: approve", 1, true) ~= nil)
    t.is_true(outcome.payload.body:find('state="ready"', 1, true) ~= nil)
  end,
}
