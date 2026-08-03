return require("testkit_internal.devloop_fixtures").new({
  core = require("core"),
  base_ids = require("devloop.base_ids"),
  entity_read_mocks = require("tests.entity_read_mock_helpers"),
  devloop_base = require("devloop.base"),
  payloads_builders = require("devloop.payloads.builders"),
  conv_reconcile = require("devloop.convergence.reconcile"),
  m_builders = require("devloop.markers.builders"),
  pr_safety = require("devloop.pr_safety"),
  consensus_call = require("devloop.consensus_call"),
  pr_origin_view_times_enabled = true,
  default_pr_origin_times = 3,
})
