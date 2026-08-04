local core = require("core")
local t = fkst.test
local gh_argv = require("testkit_internal.gh_argv_mock")
local projected_state_fixture = require("testkit_internal.projected_state_fixture")
local devloop_state = require("devloop.state")
local base_ids = require("devloop.base_ids")
gh_argv.install(t, core)

return {
  core = core,
  t = t,
  argv_rendered = gh_argv.argv_rendered,
  state_comment_request = function(proposal_id, state, version, effects)
    return projected_state_fixture.comment_request(devloop_state, base_ids, proposal_id, state, version, effects)
  end,
}
