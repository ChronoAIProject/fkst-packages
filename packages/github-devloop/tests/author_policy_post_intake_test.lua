local h = require("tests.devloop_helpers")
local t = h.t
local core = h.core

return {
  test_loop_post_intake_gate_accepts_org_member_policy = function()
    local event = h.unresolved({
      dedup_key = "consensus:github-devloop/issue/owner/repo/42/intake/1",
      round = 0,
      narrowed_question = "Which implementation path should continue?",
      angle_digests = {
        { angle = "minimal", verdict = "abstain", digest = "digest-0" },
      },
      findings_record = "open:\nneeds another round",
    })
    h.mock_issue_loop({ "fkst-dev:thinking" }, {
      h.state_marker(event.proposal_id, "thinking", event.dedup_key),
    }, {
      author_login = "org-member",
    })
    t.mock_command('printf %s "$FKST_GITHUB_AUTHORIZE_ORG_MEMBERS"', {
      stdout = "1",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command('printf %s "$FKST_GITHUB_REPO"', {
      stdout = "owner/repo",
      stderr = "",
      exit_code = 0,
    })
    t.mock_command("gh api --paginate --slurp 'orgs/owner/members?per_page=100'", {
      stdout = '[{"login":"org-member"}]',
      stderr = "",
      exit_code = 0,
    })

    local result = h.run_loop(event, h.opts("loop-post-intake-org-member-policy", {
      env = {
        FKST_GITHUB_AUTHORIZED_LOGINS = "",
      },
    }))

    t.eq(result.exit_code, 0)
    t.eq(h.take_consensus_proposal() ~= nil, true)
    t.eq(h.find_raise(result.raises, "devloop_consensus_request") ~= nil, true)
    t.eq(h.find_raise(result.raises, "github-proxy.github_issue_comment_request") ~= nil, true)
  end,
}
