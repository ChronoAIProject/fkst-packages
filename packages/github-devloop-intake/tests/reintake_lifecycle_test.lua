local devloop_base = require("devloop.base")
local devloop_state = require("devloop.state")
local h = require("tests.devloop_helpers")
local t = h.t

local proposal_id = "github-devloop/issue/owner/repo/42"

local function state_comment(state, created_at)
  return {
    body = h.core.state_marker(
      proposal_id,
      state,
      proposal_id .. "/2026-07-31T00-00-00Z/" .. state
    ),
    author_login = devloop_base.trusted_bot_login(),
    created_at = created_at,
  }
end

return {
  test_reintake_eligibility_uses_terminal_lifecycle_truth_with_blocked_exception = function()
    for _, state in ipairs({ "blocked", "declined", "merged" }) do
      local comments = { state_comment(state, "2026-07-31T02:00:00Z") }
      t.eq(devloop_state.reintake_has_active_devloop_state({}, comments, proposal_id), false)
    end

    for _, state in ipairs({ "thinking", "ready", "implementing", "impl-failed" }) do
      local comments = { state_comment(state, "2026-07-31T02:00:00Z") }
      t.eq(devloop_state.reintake_has_active_devloop_state({}, comments, proposal_id), true)
    end
  end,

  test_reintake_effect_epoch_follows_later_eligible_state_marker = function()
    local command = { created_at = "2026-07-31T01:00:00Z" }
    for _, state in ipairs({ "blocked", "declined", "merged" }) do
      local comments = { state_comment(state, "2026-07-31T02:00:00Z") }
      t.eq(devloop_state.reintake_effect_updated_at(
        { updated_at = "2026-07-31T03:00:00Z" },
        command,
        comments,
        proposal_id
      ), "2026-07-31T02:00:00Z")
    end
  end,
}
