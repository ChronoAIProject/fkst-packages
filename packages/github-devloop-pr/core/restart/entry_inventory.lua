return {
  {
    semantic_variant = "first_seen_pr",
    owner = "github-devloop-pr",
    row_id = "reviewing",
    kind = "entry",
    source = {
      state = nil,
      boundary = "github-proxy.github_entity_changed",
    },
    target = "reviewing",
    pending_order = { participates = false },
    cas_policy_id = "cas.legacy_observe_pr_v1",
    cas_variant = "pr_open_to_reviewing",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/reviewing/entry/first_seen_pr/apply",
        effect_ids = { "github-proxy.github_pr_comment_request" },
      },
      idempotent = {
        id = "github-devloop-pr/reviewing/entry/first_seen_pr/idempotent",
        effect_ids = {},
      },
    },
    provenance = {
      owner = "github-devloop-pr",
      row = "reviewing",
      field = "entry_inventory.first_seen_pr",
    },
  },
  {
    semantic_variant = "review_receiver",
    owner = "github-devloop-pr",
    row_id = "reviewing",
    kind = "entry",
    source = {
      state = nil,
      boundary = "github-devloop-pr.devloop_reviewing",
    },
    target = "reviewing",
    pending_order = { participates = false },
    cas_policy_id = "cas.legacy_review_activation_handoff_v1",
    provenance = {
      owner = "github-devloop-pr",
      row = "reviewing",
      field = "entry_inventory.review_receiver",
    },
  },
  {
    semantic_variant = "review_convergence_round",
    owner = "github-devloop-pr",
    row_id = "reviewing",
    kind = "entry",
    source = {
      state = nil,
      boundary = "consensus.consensus_converge",
    },
    target = "reviewing",
    pending_order = { participates = false },
    cas_policy_id = "cas.legacy_review_loop_safe_v1",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/reviewing/entry/review_convergence_round/apply",
        effect_ids = { "github-proxy.github_pr_comment_request" },
      },
      idempotent = {
        id = "github-devloop-pr/reviewing/entry/review_convergence_round/idempotent",
        effect_ids = {},
      },
    },
    provenance = {
      owner = "github-devloop-pr",
      row = "reviewing",
      field = "entry_inventory.review_convergence_round",
    },
  },
  {
    semantic_variant = "pr_open_handoff",
    owner = "github-devloop-pr",
    row_id = "pr-open",
    kind = "entry",
    source = {
      state = nil,
      boundary = "github-proxy.github_comment_written",
    },
    target = "pr-open",
    pending_order = { participates = false },
    provenance = {
      owner = "github-devloop-pr",
      row = "pr-open",
      field = "entry_inventory.pr_open_handoff",
    },
  },
}
