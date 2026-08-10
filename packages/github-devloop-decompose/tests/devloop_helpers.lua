local claim_carriers = require("devloop.claim_carriers")

return require("testkit_internal.devloop_helpers_fixtures").new({
  entity_lib = require("devloop.entity"),
  base = require("tests.devloop_base_helpers"),
  pr = require("tests.devloop_pr_helpers"),
  worktree = require("tests.devloop_worktree_helpers"),
  entity_read_mocks = require("tests.entity_read_mock_helpers"),
  claim_label_spec = function(owner)
    return claim_carriers.active_label_spec(false, owner)
  end,
  claim_label_is_family = claim_carriers.is_claim_family,
  mode = "decompose",
})
