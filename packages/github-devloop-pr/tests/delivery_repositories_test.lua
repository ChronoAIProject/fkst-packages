local delivery_repositories = require("devloop.delivery_repositories")
local t = require("tests.devloop_helpers").t

local PROPOSAL_ID = "github-devloop/issue/owner/lifecycle/42"
local PR_SOURCE_REF = {
  kind = "external",
  ref = "owner/implementation#pr/7",
}

return {
  test_same_repository_pair_preserves_existing_delivery_identity = function()
    local pair = delivery_repositories.resolve(
      PROPOSAL_ID,
      "owner/lifecycle",
      "owner/lifecycle"
    )

    t.eq(pair.lifecycle_repo, "owner/lifecycle")
    t.eq(pair.implementation_repo, "owner/lifecycle")
  end,

  test_cross_repository_pair_binds_pr_source_to_implementation_repository = function()
    local pair, pr_number = delivery_repositories.from_pr_source_ref(
      PROPOSAL_ID,
      PR_SOURCE_REF,
      "owner/lifecycle",
      "owner/implementation"
    )

    t.eq(pair.lifecycle_repo, "owner/lifecycle")
    t.eq(pair.implementation_repo, "owner/implementation")
    t.eq(pr_number, 7)
  end,

  test_incomplete_repository_pair_is_rejected = function()
    t.raises(function()
      delivery_repositories.resolve(PROPOSAL_ID, "owner/lifecycle", nil)
    end)
  end,

  test_lifecycle_repository_must_match_issue_proposal = function()
    t.raises(function()
      delivery_repositories.resolve(
        PROPOSAL_ID,
        "owner/other",
        "owner/implementation"
      )
    end)
  end,

  test_pr_source_repository_must_match_implementation_repository = function()
    t.raises(function()
      delivery_repositories.from_pr_source_ref(
        PROPOSAL_ID,
        PR_SOURCE_REF,
        "owner/lifecycle",
        "owner/other"
      )
    end)
  end,
}
