local h = require("tests.devloop_helpers")
local m_builders = require("devloop.markers.builders")

local t = h.t
local core = h.core

return {
  test_reached_result_cannot_complete_while_authoritative_marker_remains_thinking = function()
    local reached = h.reached()
    local comments = {
      core.state_marker(reached.proposal_id, "thinking", reached.dedup_key),
      m_builders.result_marker(reached.proposal_id, reached.decision, reached.dedup_key),
    }

    h.mock_issue_result({ "fkst-dev:ready" }, comments)
    local result = h.run_result(reached, h.opts("consensus-projection-rootcause"))
    local authoritative = core.current_state(comments, reached.proposal_id)

    if result.exit_code == 0
      and #result.raises == 0
      and authoritative.state == "thinking" then
      error(table.concat({
        "REPRODUCED consensus projection loss:",
        "a reached result was acknowledged with zero raises because the target label matched;",
        "authoritative marker remained thinking",
      }, " "))
    end

    t.is_true(h.find_raise(result.raises, "github-proxy.github_issue_comment_request") ~= nil,
      "a reached result must reproject the authoritative target state before it can be complete")
  end,

  test_reached_result_is_idempotent_when_authoritative_marker_is_already_ready = function()
    local reached = h.reached()
    local comments = {
      h.projected_state_comment(reached.proposal_id, "ready", reached.dedup_key),
      m_builders.result_marker(reached.proposal_id, reached.decision, reached.dedup_key),
    }

    h.mock_issue_result({ "fkst-dev:ready" }, comments)
    local result = h.run_result(reached, h.opts("consensus-projection-idempotent"))

    t.eq(result.exit_code, 0)
    t.eq(#result.raises, 0)
  end,
}
