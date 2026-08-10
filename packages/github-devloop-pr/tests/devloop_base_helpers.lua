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
  review_loop_department = require("departments.review_loop.main"),
  review_result_department = require("departments.review_result.main"),
  decompose_queue = "github-devloop-decompose.devloop_decompose",
  mock_merge_pr_diff_name_only = true,
  projected_state_comment = require("testkit_internal.projected_state_fixture").bind(require("devloop.state")),
  claim_label_spec = function(owner)
    return claim_carriers.active_label_spec(false, owner)
  end,
  claim_label_is_family = claim_carriers.is_claim_family,
})
