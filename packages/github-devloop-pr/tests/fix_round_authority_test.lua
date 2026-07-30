local h = require("tests.devloop_helpers")
local config = require("devloop.config")
local fix_round_authority = require("devloop.fix_round_authority")
local devloop_state = require("devloop.state")
local transition_version = require("contract.transition_version")

local t = h.t

return {
  test_raw_fix_round_constructor_is_not_exported = function()
    t.eq(devloop_state.next_fix_version, nil)
    t.eq(devloop_state.fix_version_from_review_version, nil)
    t.eq(transition_version.next_fix, nil)
  end,

  test_fix_round_authority_is_the_only_cap_checked_advancer = function()
    local version = h.reviewing().version
    for round = 1, config.max_fix_rounds() do
      local transition = fix_round_authority.next_or_decompose(version)
      t.eq(transition.kind, "advance")
      t.eq(transition.round, round)
      version = transition.version
    end

    local capped = fix_round_authority.next_or_decompose(version)
    t.eq(capped.kind, "decompose")
    t.eq(capped.version, version)
    t.eq(capped.round, config.max_fix_rounds())
  end,
}
