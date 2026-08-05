
local owner = "github-devloop-pr"
local proposal_id = "github-devloop/issue/owner/repo/42"
local pr_number = 7
local version = "ready/consensus-github-devloop/issue/owner/repo/42/2026-06-03T01-02-03Z"
local branch = "devloop-owner-repo-42-01HY"
local base_branch = "dev"
local structural_fields = {
  "id",
  "owner",
  "row_id",
  "kind",
  "source",
  "target",
  "semantic_variant",
  "provenance",
}

local expected_entries = {
  ["github-devloop-pr/reviewing/entry/first_seen_pr"] = {
    row_id = "reviewing",
    output_variant = "first_seen_pr",
    source_state = nil,
    source_boundary = "github-proxy.github_entity_changed",
    target = "reviewing",
    field = "entry_inventory.first_seen_pr",
    semantic_variant = "first_seen_pr",
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
  },
  ["github-devloop-pr/reviewing/entry/review_receiver"] = {
    row_id = "reviewing",
    output_variant = "review_receiver",
    source_state = nil,
    source_boundary = "github-devloop-pr.devloop_reviewing",
    target = "reviewing",
    field = "entry_inventory.review_receiver",
    semantic_variant = "review_receiver",
    cas_policy_id = "cas.legacy_review_activation_handoff_v1",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/reviewing/entry/review_receiver/apply",
        effect_ids = {},
      },
      idempotent = {
        id = "github-devloop-pr/reviewing/entry/review_receiver/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/reviewing/entry/review_convergence_round"] = {
    row_id = "reviewing",
    output_variant = "review_convergence_round",
    source_state = nil,
    source_boundary = "github-devloop-pr.devloop_review_continue",
    target = "reviewing",
    field = "entry_inventory.review_convergence_round",
    semantic_variant = "review_convergence_round",
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
  },
  ["github-devloop-pr/pr-open/entry/pr_open_handoff"] = {
    row_id = "pr-open",
    output_variant = "pr_open_handoff",
    source_state = nil,
    source_boundary = "github-proxy.github_comment_written",
    target = "pr-open",
    field = "entry_inventory.pr_open_handoff",
    semantic_variant = "pr_open_handoff",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/pr-open/entry/pr_open_handoff/apply",
        effect_ids = { "devloop_observe_pr" },
      },
      idempotent = {
        id = "github-devloop-pr/pr-open/entry/pr_open_handoff/idempotent",
        effect_ids = { "devloop_observe_pr" },
      },
    },
  },
  ["github-devloop-pr/merge-ready/entry/handoff_to_merge_gate"] = {
    row_id = "merge-ready",
    output_variant = "handoff_to_merge_gate",
    source_state = "merge-ready",
    source_boundary = nil,
    target = "merging",
    field = "receiver_activations",
    semantic_variant = "handoff_to_merge_gate",
    cas_policy_id = "cas.legacy_merge_v1",
    cas_variant = "merge_ready_or_merging_to_merging",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/merge-ready/entry/handoff_to_merge_gate/apply",
        effect_ids = { "github-proxy.github_pr_comment_request" },
      },
      idempotent = {
        id = "github-devloop-pr/merge-ready/entry/handoff_to_merge_gate/idempotent",
        effect_ids = { "github-proxy.github_pr_comment_request" },
      },
    },
  },
  ["github-devloop-pr/reviewing/entry/review_reject_to_blocked"] = {
    row_id = "reviewing",
    output_variant = "review_reject_to_blocked",
    source_state = "reviewing",
    source_boundary = "devloop_fix_reconcile",
    target = "blocked",
    field = "receiver_activations",
    semantic_variant = "review_reject_to_blocked",
    cas_policy_id = "cas.legacy_pr_fix_reconcile_v1",
    cas_variant = "review_reject_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/reviewing/entry/review_reject_to_blocked/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/reviewing/entry/review_reject_to_blocked/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/fixing/entry/review_reject_to_blocked"] = {
    row_id = "fixing",
    output_variant = "review_reject_to_blocked",
    source_state = "fixing",
    source_boundary = "devloop_fix_reconcile",
    target = "blocked",
    field = "receiver_activations",
    semantic_variant = "review_reject_to_blocked",
    cas_policy_id = "cas.legacy_pr_fix_reconcile_v1",
    cas_variant = "review_reject_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/fixing/entry/review_reject_to_blocked/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/fixing/entry/review_reject_to_blocked/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/fixing/entry/bounded_fix_to_blocked"] = {
    row_id = "fixing",
    output_variant = "bounded_fix_to_blocked",
    source_state = "fixing",
    source_boundary = "devloop_fix_reconcile",
    target = "blocked",
    field = "receiver_activations",
    semantic_variant = "bounded_fix_to_blocked",
    cas_policy_id = "cas.legacy_pr_fix_reconcile_v1",
    cas_variant = "bounded_fix_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/fixing/entry/bounded_fix_to_blocked/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/fixing/entry/bounded_fix_to_blocked/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/merge-ready/entry/review_reject_to_blocked"] = {
    row_id = "merge-ready",
    output_variant = "review_reject_to_blocked",
    source_state = "merge-ready",
    source_boundary = "devloop_fix_reconcile",
    target = "blocked",
    field = "receiver_activations",
    semantic_variant = "review_reject_to_blocked",
    cas_policy_id = "cas.legacy_pr_fix_reconcile_v1",
    cas_variant = "review_reject_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/merge-ready/entry/review_reject_to_blocked/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/merge-ready/entry/review_reject_to_blocked/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/merge-ready/entry/bounded_fix_to_blocked"] = {
    row_id = "merge-ready",
    output_variant = "bounded_fix_to_blocked",
    source_state = "merge-ready",
    source_boundary = "devloop_fix_reconcile",
    target = "blocked",
    field = "receiver_activations",
    semantic_variant = "bounded_fix_to_blocked",
    cas_policy_id = "cas.legacy_pr_fix_reconcile_v1",
    cas_variant = "bounded_fix_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/merge-ready/entry/bounded_fix_to_blocked/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/merge-ready/entry/bounded_fix_to_blocked/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/merging/entry/review_reject_to_blocked"] = {
    row_id = "merging",
    output_variant = "review_reject_to_blocked",
    source_state = "merging",
    source_boundary = "devloop_fix_reconcile",
    target = "blocked",
    field = "receiver_activations",
    semantic_variant = "review_reject_to_blocked",
    cas_policy_id = "cas.legacy_pr_fix_reconcile_v1",
    cas_variant = "review_reject_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/merging/entry/review_reject_to_blocked/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/merging/entry/review_reject_to_blocked/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/merging/entry/bounded_fix_to_blocked"] = {
    row_id = "merging",
    output_variant = "bounded_fix_to_blocked",
    source_state = "merging",
    source_boundary = "devloop_fix_reconcile",
    target = "blocked",
    field = "receiver_activations",
    semantic_variant = "bounded_fix_to_blocked",
    cas_policy_id = "cas.legacy_pr_fix_reconcile_v1",
    cas_variant = "bounded_fix_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/merging/entry/bounded_fix_to_blocked/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/merging/entry/bounded_fix_to_blocked/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/reviewing/entry/review_reconcile_true_stall"] = {
    row_id = "reviewing", output_variant = "review_reconcile_true_stall",
    source_state = "reviewing", source_boundary = "devloop_review_reconcile",
    target = "blocked", field = "receiver_activations",
    semantic_variant = "review_reconcile_true_stall",
    cas_policy_id = "cas.legacy_issue_reconcile_v1", cas_variant = "reviewing_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/reviewing/entry/review_reconcile_true_stall/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/reviewing/entry/review_reconcile_true_stall/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/fixing/entry/watchdog_reconcile_terminal"] = {
    row_id = "fixing", output_variant = "watchdog_reconcile_terminal",
    source_state = "fixing", source_boundary = "devloop_timeout_reconcile",
    target = "blocked", field = "receiver_activations",
    semantic_variant = "watchdog_reconcile_terminal",
    cas_policy_id = "cas.legacy_timeout_reconcile_v1", cas_variant = "fixing_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/fixing/entry/watchdog_reconcile_terminal/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/fixing/entry/watchdog_reconcile_terminal/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/merging/entry/watchdog_reconcile_terminal"] = {
    row_id = "merging", output_variant = "watchdog_reconcile_terminal",
    source_state = "merging", source_boundary = "devloop_timeout_reconcile",
    target = "blocked", field = "receiver_activations",
    semantic_variant = "watchdog_reconcile_terminal",
    cas_policy_id = "cas.legacy_timeout_reconcile_v1", cas_variant = "merging_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/merging/entry/watchdog_reconcile_terminal/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/merging/entry/watchdog_reconcile_terminal/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/pr-open/entry/watchdog_reconcile_terminal"] = {
    row_id = "pr-open", output_variant = "watchdog_reconcile_terminal",
    source_state = "pr-open", source_boundary = "devloop_timeout_reconcile",
    target = "blocked", field = "receiver_activations",
    semantic_variant = "watchdog_reconcile_terminal",
    cas_policy_id = "cas.legacy_timeout_reconcile_v1", cas_variant = "pr_open_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/pr-open/entry/watchdog_reconcile_terminal/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/pr-open/entry/watchdog_reconcile_terminal/idempotent",
        effect_ids = {},
      },
    },
  },
  ["github-devloop-pr/review-meta/entry/watchdog_reconcile_terminal"] = {
    row_id = "review-meta", output_variant = "watchdog_reconcile_terminal",
    source_state = "review-meta", source_boundary = "devloop_timeout_reconcile",
    target = "blocked", field = "receiver_activations",
    semantic_variant = "watchdog_reconcile_terminal",
    cas_policy_id = "cas.legacy_timeout_reconcile_v1", cas_variant = "review_meta_to_blocked",
    transition_effect_entitlements = {
      apply = {
        id = "github-devloop-pr/review-meta/entry/watchdog_reconcile_terminal/apply",
        effect_ids = {
          "github-proxy.github_pr_comment_request",
          "github-proxy.github_issue_label_request",
        },
      },
      idempotent = {
        id = "github-devloop-pr/review-meta/entry/watchdog_reconcile_terminal/idempotent",
        effect_ids = {},
      },
    },
  },
}

local pending_order_goldens = {
  ["github-devloop-pr/reviewing/entry/first_seen_pr"] = { participates = false },
  ["github-devloop-pr/reviewing/entry/review_receiver"] = { participates = false },
  ["github-devloop-pr/reviewing/entry/review_convergence_round"] = { participates = false },
  ["github-devloop-pr/pr-open/entry/pr_open_handoff"] = { participates = false },
  ["github-devloop-pr/merge-ready/entry/handoff_to_merge_gate"] = { participates = true, predecessor_state = "merge-ready" },
  ["github-devloop-pr/reviewing/entry/review_reject_to_blocked"] = { participates = false },
  ["github-devloop-pr/fixing/entry/review_reject_to_blocked"] = { participates = false },
  ["github-devloop-pr/fixing/entry/bounded_fix_to_blocked"] = { participates = false },
  ["github-devloop-pr/merge-ready/entry/review_reject_to_blocked"] = { participates = false },
  ["github-devloop-pr/merge-ready/entry/bounded_fix_to_blocked"] = { participates = false },
  ["github-devloop-pr/merging/entry/review_reject_to_blocked"] = { participates = false },
  ["github-devloop-pr/merging/entry/bounded_fix_to_blocked"] = { participates = false },
  ["github-devloop-pr/reviewing/entry/review_reconcile_true_stall"] = { participates = false },
  ["github-devloop-pr/fixing/entry/watchdog_reconcile_terminal"] = { participates = false },
  ["github-devloop-pr/merging/entry/watchdog_reconcile_terminal"] = { participates = false },
  ["github-devloop-pr/pr-open/entry/watchdog_reconcile_terminal"] = { participates = false },
  ["github-devloop-pr/review-meta/entry/watchdog_reconcile_terminal"] = { participates = false },
}

return {
  owner = owner,
  proposal_id = proposal_id,
  pr_number = pr_number,
  version = version,
  branch = branch,
  base_branch = base_branch,
  structural_fields = structural_fields,
  expected_entries = expected_entries,
  pending_order_goldens = pending_order_goldens,
}
