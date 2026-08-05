return require("testkit_internal.devloop_core_fixtures").new({
  core = require("core"),
  projected_state_comment = require("testkit_internal.projected_state_fixture").bind(require("devloop.state")),
})
