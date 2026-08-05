local core = require("core")
local t = fkst.test
local gh_argv = require("testkit_internal.gh_argv_mock")
local observe_commands = require("devloop.commands.observe_lists")
gh_argv.install(t, core)
observe_commands.gh_issue_list_observe_opts = core.gh_issue_list_observe_opts
observe_commands.gh_pr_list_observe_opts = core.gh_pr_list_observe_opts

return {
  core = core,
  t = t,
  projected_state_comment = require("testkit_internal.projected_state_fixture").bind(require("devloop.state")),
  argv_rendered = gh_argv.argv_rendered,
}
