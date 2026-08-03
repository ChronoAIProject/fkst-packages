local core = require("core")
local t = fkst.test
local gh_argv = require("testkit_internal.gh_argv_mock")
local projected_state_fixture = require("testkit_internal.projected_state_fixture")
local base_ids = require("devloop.base_ids")
gh_argv.install(t, core)

return {
  core = core,
  t = t,
  argv_rendered = gh_argv.argv_rendered,
  state_marker = function(proposal_id, state, version, effects)
    return projected_state_fixture.state_marker(core, base_ids, proposal_id, state, version, effects)
  end,
}
