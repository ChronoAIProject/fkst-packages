return require("testkit.devloop_fixtures").new({
  core = require("core"),
  entity_read_mocks = require("tests.entity_read_mock_helpers"),
  devloop_base = require("devloop.base"),
  payloads_builders = require("devloop.payloads.builders"),
  conv_reconcile = require("devloop.convergence.reconcile"),
  m_builders = require("devloop.markers.builders"),
  pr_safety = require("devloop.pr_safety"),
  fix_round_authority = require("devloop.fix_round_authority"),
  pr_origin_view_times_enabled = true,
  default_pr_origin_times = 6,
  pr_fix_precheck_from_cached = true,
})
