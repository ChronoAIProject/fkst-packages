local claim_carriers = require("devloop.claim_carriers")

return require("testkit_internal.devloop_fixtures").new({
  core = require("core"),
  entity_read_mocks = require("tests.entity_read_mock_helpers"),
  devloop_base = require("devloop.base"),
  parsers_misc = require("devloop.parsers.misc"),
  payloads_builders = require("devloop.payloads.builders"),
  conv_reconcile = require("devloop.convergence.reconcile"),
  m_builders = require("devloop.markers.builders"),
  pr_safety = require("devloop.pr_safety"),
  consensus_call = require("devloop.consensus_call"),
  consensus_result_department = require("departments.consensus_result.main"),
  loop_department = require("departments.loop.main"),
  pr_origin_view_times_enabled = true,
  default_pr_origin_times = 3,
  projected_state_comment = require("testkit_internal.projected_state_fixture").bind(require("devloop.state")),
  claim_label_spec = function(owner)
    return claim_carriers.active_label_spec(false, owner)
  end,
  claim_label_is_family = claim_carriers.is_claim_family,
  state_comment = require("testkit_internal.projected_state_fixture").bind_state_comment(require("devloop.state")),
})
